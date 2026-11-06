// The note editor of the Apple app: the web client's CodeMirror editor
// (@ivynote/editor, live preview) in a WKWebView, driven over a small bridge.
//
// Swift → JS: window.ivy.load / setBody / setTitles / setKinds / setKind /
//             setTheme / setLanguage / setReadonly / focus / command / scrollToLine /
//             insert / setBacklinks / render
// JS → Swift: webkit.messageHandlers.ivy.postMessage({ type, ... })
//   ready              the page can take a document
//   change {id, body}  the user edited the note
//   open {id, title}   a wiki link was followed ('' id: no such note)
//   focus {focused}    the editor gained or lost the keyboard
//   scroll {line}      the 0-based line at the top of the view (the outline)
//   files {files}      files pasted or dropped: [{name, type, data (base64)}]
//   error {message}    an uncaught script error, for the debug log

import { autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap } from '@codemirror/autocomplete';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { highlightSelectionMatches, search, searchKeymap } from '@codemirror/search';
import { Compartment, EditorState } from '@codemirror/state';
import { EditorView, keymap, placeholder } from '@codemirror/view';
import { insertLink, insertText, insertWiki, toggleLinePrefix, toggleWrap } from '@ivynote/editor/commands';
import { livePreview, type PreviewOptions } from '@ivynote/editor/livePreview';
import { baseTheme, markdownHighlight } from '@ivynote/editor/theme';
import { wikiCompletion } from '@ivynote/editor/wikiComplete';
import { normalizeTitle } from '@ivynote/core/markdown/links';
import { renderMarkdown } from '@ivynote/core/markdown/render';

type Msg = { type: string; [k: string]: unknown };

interface TitleEntry {
	id: string;
	title: string;
	folder?: string;
}

interface LoadPayload {
	id: string;
	body: string;
	readonly?: boolean;
	fontSize?: number;
	focus?: boolean;
}

declare global {
	interface Window {
		webkit?: { messageHandlers?: { ivy?: { postMessage(m: Msg): void } } };
		ivy: Record<string, (...a: never[]) => unknown>;
	}
}

function post(m: Msg) {
	window.webkit?.messageHandlers?.ivy?.postMessage(m);
}

// --- state shared with the preview options ---

let noteId = '';
let titles: TitleEntry[] = [];
let byTitle = new Map<string, string>();
let kinds: Record<string, string> = {};
let lastEmitted = '';
let view: EditorView | null = null;
const roConf = new Compartment();
const placeholderConf = new Compartment();

// --- the interface language (setLanguage): the placeholder, the words
// formatting wraps around an empty selection, the backlinks ---

const words = {
	zh: {
		placeholder: '开始写作…', bold: '加粗', italic: '斜体', strike: '删除线', untitled: '无标题',
		backlinks: '反向链接', backlinkCount: (n: number) => `${n} 条反向链接`
	},
	en: {
		placeholder: 'Start writing…', bold: 'bold', italic: 'italic', strike: 'strikethrough', untitled: 'Untitled',
		backlinks: 'Backlinks', backlinkCount: (n: number) => `${n} ${n === 1 ? 'backlink' : 'backlinks'}`
	}
};
let lang: keyof typeof words = 'zh';
const w = () => words[lang];

/** Same-origin path the native scheme handler answers with the attachment. */
function resource(id: string, thumb?: boolean): string {
	return `/res/${encodeURIComponent(id)}${thumb ? '?thumb=1' : ''}`;
}

const options: PreviewOptions = {
	resolveResource: resource,
	resourceKind: (id) => kinds[id] ?? 'image',
	resolveTitle: (title) => byTitle.get(normalizeTitle(title.split('#')[0].split('|')[0])) ?? '',
	openNote: (id, title) => post({ type: 'open', id, title }),
	renderBlock: (md) =>
		renderMarkdown(md, {
			resolveResource: resource,
			resourceKind: (id) => kinds[id],
			resolveTitle: (t) => options.resolveTitle(t),
			noteHref: () => '#'
		})
};

function completions() {
	return titles.filter((t) => t.id !== noteId && t.title).map((t) => ({ title: t.title, detail: t.folder }));
}

function extensions(readonly: boolean) {
	return [
		history(),
		closeBrackets(),
		search({ top: true }),
		highlightSelectionMatches(),
		markdown({ base: markdownLanguage, addKeymap: true }),
		markdownHighlight,
		baseTheme,
		EditorView.lineWrapping,
		placeholderConf.of(placeholder(w().placeholder)),
		autocompletion({ override: [wikiCompletion(completions)], icons: false, activateOnTyping: true }),
		keymap.of([
			{ key: 'Mod-b', run: (v) => toggleWrap(v, '**', w().bold) },
			{ key: 'Mod-i', run: (v) => toggleWrap(v, '*', w().italic) },
			{ key: 'Mod-e', run: (v) => toggleWrap(v, '`', 'code') },
			{ key: 'Mod-Shift-x', run: (v) => toggleWrap(v, '~~', w().strike) },
			{ key: 'Mod-k', run: insertLink },
			{ key: 'Mod-Shift-k', run: insertWiki },
			{ key: 'Mod-Alt-1', run: (v) => toggleLinePrefix(v, '# ') },
			{ key: 'Mod-Alt-2', run: (v) => toggleLinePrefix(v, '## ') },
			{ key: 'Mod-Alt-3', run: (v) => toggleLinePrefix(v, '### ') },
			{ key: 'Mod-Shift-7', run: (v) => toggleLinePrefix(v, '1. ') },
			{ key: 'Mod-Shift-8', run: (v) => toggleLinePrefix(v, '- ') },
			{ key: 'Mod-Shift-9', run: (v) => toggleLinePrefix(v, '- [ ] ') },
			...closeBracketsKeymap,
			...completionKeymap,
			...searchKeymap,
			...historyKeymap,
			indentWithTab,
			...defaultKeymap
		]),
		livePreview(options),
		EditorView.contentAttributes.of({ class: 'cm-live' }),
		roConf.of(EditorState.readOnly.of(readonly)),
		EditorView.domEventHandlers({
			paste(e) {
				const files = [...(e.clipboardData?.files ?? [])];
				if (!files.length || readOnlyNow()) return false;
				e.preventDefault();
				void sendFiles(files);
				return true;
			},
			drop(e, v) {
				const files = [...(e.dataTransfer?.files ?? [])];
				if (!files.length || readOnlyNow()) return false;
				e.preventDefault();
				const pos = v.posAtCoords({ x: e.clientX, y: e.clientY });
				if (pos != null) v.dispatch({ selection: { anchor: pos } });
				void sendFiles(files);
				return true;
			}
		}),
		EditorView.updateListener.of((u) => {
			if (u.focusChanged) post({ type: 'focus', focused: u.view.hasFocus });
			if (!u.docChanged) return;
			const text = u.state.doc.toString();
			lastEmitted = text;
			post({ type: 'change', id: noteId, body: text });
		})
	];
}

const host = document.getElementById('editor')!;
const footer = document.getElementById('footer');
// The space below the body belongs to it: a tap there writes at the end.
footer?.addEventListener('click', (e) => {
	if (e.target === footer && !readOnlyNow()) window.ivy.focus(true);
});

function readOnlyNow(): boolean {
	return !view || view.state.readOnly;
}

/** Hands pasted or dropped files to the app, which uploads them and inserts
 *  the references (guide 7.1). */
async function sendFiles(files: File[]) {
	for (const f of files) {
		const data = await new Promise<string>((resolve, reject) => {
			const r = new FileReader();
			r.onload = () => resolve(String(r.result).replace(/^data:[^,]*,/, ''));
			r.onerror = () => reject(r.error);
			r.readAsDataURL(f);
		}).catch(() => '');
		if (data) post({ type: 'files', files: [{ name: f.name, type: f.type, data }] });
	}
}

interface Backlink {
	id: string;
	title: string;
	context: string;
}

/** The notes that link here, below the body as on the web (guide 11.3). */
let backlinks: Backlink[] = [];
function renderBacklinks(list: Backlink[]) {
	if (!footer) return;
	footer.replaceChildren();
	if (!list.length) return;
	const section = document.createElement('section');
	section.className = 'ivy-backlinks';
	section.setAttribute('aria-label', w().backlinks);
	const head = document.createElement('div');
	head.className = 'eyebrow';
	head.textContent = w().backlinkCount(list.length);
	section.append(head);
	for (const b of list) {
		const a = document.createElement('button');
		a.type = 'button';
		a.className = 'ivy-backlink';
		const t = document.createElement('span');
		t.className = 'ivy-backlink-title';
		t.textContent = b.title || w().untitled;
		const c = document.createElement('span');
		c.className = 'ivy-backlink-context';
		c.textContent = b.context || '…';
		a.append(t, c);
		a.addEventListener('click', () => post({ type: 'open', id: b.id, title: b.title }));
		section.append(a);
	}
	footer.append(section);
}

// The page scrolls, not CodeMirror. Report the line at the top of the
// window, once per frame, so the outline can mark where the reader is.
let lastTop = -1;
let topQueued = false;
function reportTop() {
	topQueued = false;
	if (!view) return;
	// A little below the top edge: a heading just scrolled to counts as read.
	const block = view.lineBlockAtHeight(48 - view.documentTop);
	const line = view.state.doc.lineAt(Math.min(block.from, view.state.doc.length)).number - 1;
	if (line === lastTop) return;
	lastTop = line;
	post({ type: 'scroll', line });
}
window.addEventListener(
	'scroll',
	() => {
		if (topQueued) return;
		topQueued = true;
		requestAnimationFrame(reportTop);
	},
	{ passive: true }
);

window.ivy = {
	/** Opens a note: a fresh state, so undo history never crosses notes. */
	load(p: LoadPayload) {
		noteId = p.id;
		lastEmitted = p.body;
		if (p.fontSize) document.documentElement.style.setProperty('--editor-size', `${p.fontSize}px`);
		const state = EditorState.create({ doc: p.body, extensions: extensions(!!p.readonly) });
		if (view) view.setState(state);
		else view = new EditorView({ state, parent: host });
		renderBacklinks([]);
		view.scrollDOM.scrollTop = 0;
		document.scrollingElement?.scrollTo(0, 0);
		lastTop = -1;
		reportTop();
		if (p.focus) window.ivy.focus(true);
	},

	/** A body that changed elsewhere (sync, merge). Applies the minimal diff
	 *  so the cursor stays where it is. */
	setBody(id: string, v: string) {
		if (!view || id !== noteId || v === lastEmitted) return;
		const cur = view.state.doc.toString();
		lastEmitted = v;
		if (v === cur) return;
		let start = 0;
		while (start < cur.length && start < v.length && cur[start] === v[start]) start++;
		let endCur = cur.length;
		let endNew = v.length;
		while (endCur > start && endNew > start && cur[endCur - 1] === v[endNew - 1]) {
			endCur--;
			endNew--;
		}
		view.dispatch({ changes: { from: start, to: endCur, insert: v.slice(start, endNew) } });
	},

	setTitles(list: TitleEntry[]) {
		titles = list;
		byTitle = new Map();
		// Most recently updated first: the first match wins.
		for (const t of list) {
			const k = normalizeTitle(t.title);
			if (k && !byTitle.has(k)) byTitle.set(k, t.id);
		}
		// Re-render links whose target may have appeared.
		view?.dispatch({});
	},

	setKinds(map: Record<string, string>) {
		kinds = map;
	},

	/** A file just added, before its reference goes into the body. */
	setKind(id: string, kind: string) {
		kinds[id] = kind;
	},

	/** Inserts text at the cursor; `block` puts it on a line of its own. */
	insert(text: string, block = false) {
		if (!view || view.state.readOnly) return;
		insertText(view, text, block);
	},

	setBacklinks(list: Backlink[]) {
		backlinks = list;
		renderBacklinks(list);
	},

	/** `zh` or `en`, as the app's interface. */
	setLanguage(l: string) {
		lang = l === 'en' ? 'en' : 'zh';
		document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
		view?.dispatch({ effects: placeholderConf.reconfigure(placeholder(w().placeholder)) });
		renderBacklinks(backlinks);
	},

	/** Markdown as HTML, for copying a note as rich text. */
	render(md: string): string {
		return renderMarkdown(md, {
			resolveResource: (id) => id,
			resourceKind: (id) => kinds[id],
			resolveTitle: () => '',
			noteHref: () => '#'
		});
	},

	setTheme(dark: boolean) {
		document.documentElement.dataset.theme = dark ? 'dark' : 'light';
	},

	setReadonly(ro: boolean) {
		view?.dispatch({ effects: roConf.reconfigure(EditorState.readOnly.of(ro)) });
	},

	focus(atEnd = false) {
		if (!view) return;
		view.focus();
		if (atEnd) view.dispatch({ selection: { anchor: view.state.doc.length }, scrollIntoView: true });
	},

	/** Jumps to a 0-based line (the outline), its heading at the top. */
	scrollToLine(line: number, focus = false) {
		if (!view) return;
		const l = view.state.doc.line(Math.min(Math.max(1, line + 1), view.state.doc.lines));
		view.dispatch({ selection: { anchor: l.from }, effects: EditorView.scrollIntoView(l.from, { y: 'start', yMargin: 24 }) });
		if (focus) view.focus();
	},

	/** Formatting from the native toolbar. */
	command(name: string) {
		if (!view) return;
		switch (name) {
			case 'bold': toggleWrap(view, '**', w().bold); break;
			case 'italic': toggleWrap(view, '*', w().italic); break;
			case 'strike': toggleWrap(view, '~~', w().strike); break;
			case 'code': toggleWrap(view, '`', 'code'); break;
			case 'h1': toggleLinePrefix(view, '# '); break;
			case 'h2': toggleLinePrefix(view, '## '); break;
			case 'h3': toggleLinePrefix(view, '### '); break;
			case 'list': toggleLinePrefix(view, '- '); break;
			case 'ordered': toggleLinePrefix(view, '1. '); break;
			case 'task': toggleLinePrefix(view, '- [ ] '); break;
			case 'quote': toggleLinePrefix(view, '> '); break;
			case 'link': insertLink(view); break;
			case 'wiki': insertWiki(view); break;
			case 'rule': insertText(view, '---', true); break;
			case 'undo': import('@codemirror/commands').then((m) => view && m.undo(view)); return;
			case 'redo': import('@codemirror/commands').then((m) => view && m.redo(view)); return;
			case 'blur': view.contentDOM.blur(); return;
		}
		view.focus();
	}
} as unknown as Window['ivy'];

window.addEventListener('error', (e) => post({ type: 'error', message: String(e.message) }));
// Media that fails to load (offline, deleted attachment) is worth a log line.
document.addEventListener(
	'error',
	(e) => {
		const t = e.target as HTMLElement | null;
		if (t && 'src' in t && t !== (window as unknown)) post({ type: 'log', message: `failed to load ${(t as HTMLImageElement).src}` });
	},
	true
);
post({ type: 'ready' });
