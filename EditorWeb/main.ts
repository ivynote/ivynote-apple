// The note editor of the Apple app: the web client's CodeMirror editor
// (@ivynote/editor, live preview) in a WKWebView, driven over a small bridge.
//
// Swift → JS: window.ivy.load / setBody / setTitles / setKinds / setKind /
//             setTheme / setLanguage / setReadonly / focus / command / scrollToLine /
//             insert / insertAttachment / normalizeResource / setBacklinks / render
// JS → Swift: webkit.messageHandlers.ivy.postMessage({ type, ... })
//   ready              the page can take a document
//   change {id, body}  the user edited the note
//   open {id, title}   a wiki link was followed ('' id: no such note)
//   focus {focused}    the editor gained or lost the keyboard
//   scroll {line}      the 0-based line at the top of the view (the outline)
//   files {files}      files pasted or dropped: [{name, type, data (base64)}]
//   error {message}    an uncaught script error, for the debug log
//   protection {id, protected, locked}
//                      whether the open note has a password, and is locked
//
//   pick {kind}        the insert menu asks for a photo ('image') or a file ('file')
//
// command() also takes: insert (the "/" menu at the cursor, for a ＋ button),
// due (date picker for the task at the cursor),
// protect / unprotect / changePassword / lock (guide 8.4). A protected note's
// body only ever leaves this page sealed.

import { autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap } from '@codemirror/autocomplete';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { highlightSelectionMatches, search, searchKeymap } from '@codemirror/search';
import { Compartment, EditorState, Transaction } from '@codemirror/state';
import { EditorView, keymap, placeholder } from '@codemirror/view';
import { insertLink, insertText, insertWiki, toggleLinePrefix, toggleWrap } from '@ivynote/editor/commands';
import { livePreview, type PreviewOptions } from '@ivynote/editor/livePreview';
import { baseTheme, markdownHighlight } from '@ivynote/editor/theme';
import { wikiCompletion } from '@ivynote/editor/wikiComplete';
import { dateCompletion, openDuePicker } from '@ivynote/editor/dates';
import { insertMenu, insertMenuLook, openInsertMenu, slashCompletion } from '@ivynote/editor/insert';
import { selectionToolbar } from '@ivynote/editor/bubble';
import { Protection } from '@ivynote/editor/protection';
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
let userPlacedCursor = false;
let pendingNormalizations: Array<{ localId: string; remoteId: string }> = [];
const roConf = new Compartment();
const placeholderConf = new Compartment();

// --- the interface language (setLanguage): the placeholder, the words
// formatting wraps around an empty selection, the backlinks ---

const words = {
	zh: {
		placeholder: '开始写作…', bold: '加粗', italic: '斜体', strike: '删除线', untitled: '无标题',
		backlinks: '反向链接', backlinkCount: (n: number) => `${n} 条反向链接`,
		loadingImage: '图片加载中…', brokenImage: '图片无法显示'
	},
	en: {
		placeholder: 'Start writing…', bold: 'bold', italic: 'italic', strike: 'strikethrough', untitled: 'Untitled',
		backlinks: 'Backlinks', backlinkCount: (n: number) => `${n} ${n === 1 ? 'backlink' : 'backlinks'}`,
		loadingImage: 'Loading image…', brokenImage: 'Image unavailable'
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
		// "/" opens the insert menu; photos and files are picked by the app.
		autocompletion({ override: [slashCompletion({ hosts: ['image', 'file'], host: (kind) => post({ type: 'pick', kind }) }), dateCompletion, wikiCompletion(completions)], icons: false, activateOnTyping: true, maxRenderedOptions: 40, ...insertMenuLook }),
		insertMenu(),
		selectionToolbar(),
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
			{ key: 'Mod-Shift-d', run: (v) => (openDuePicker(v), true) },
			{ key: 'Mod-/', run: openInsertMenu },
			{ key: 'Mod-Shift-h', run: (v) => toggleWrap(v, '==') },
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
				if (pos != null) {
					userPlacedCursor = true;
					v.dispatch({ selection: { anchor: pos } });
				}
				void sendFiles(files);
				return true;
			},
			compositionend() {
				if (pendingNormalizations.length) queueMicrotask(flushPendingNormalizations);
				return false;
			}
		}),
		EditorView.updateListener.of((u) => {
			if (u.focusChanged) post({ type: 'focus', focused: u.view.hasFocus });
			if (u.selectionSet && !u.transactions.every((tr) => tr.annotation(Transaction.remote))) {
				userPlacedCursor = true;
			}
			if (pendingNormalizations.length && !u.view.compositionStarted) {
				queueMicrotask(flushPendingNormalizations);
			}
			if (!u.docChanged) return;
			// Text put in from outside (sync, another device) is not sent back.
			if (u.transactions.every((tr) => tr.annotation(Transaction.remote))) return;
			// A protected note leaves the page sealed (guide 8.4).
			const body = protection.edited(u.state.doc.toString());
			lastEmitted = body;
			post({ type: 'change', id: noteId, body });
		})
	];
}

const host = document.getElementById('editor')!;
let loadReadonly = false;

// --- Image loading placeholders: subtle shimmer while fetching remote bytes,
// zero flash for instant local/cached images. ---

const wiredImages = new WeakSet<HTMLImageElement>();

function wireMediaImage(img: HTMLImageElement) {
	if (wiredImages.has(img)) return;
	wiredImages.add(img);
	const wrap = img.closest('.cm-media') as HTMLElement | null;
	if (!wrap) return;
	const label = img.alt || w().loadingImage;

	const finishLoaded = () => {
		if (timer != null) {
			window.clearTimeout(timer);
			timer = null;
		}
		wrap.classList.remove('cm-media-loading', 'cm-media-broken');
		wrap.classList.add('cm-media-loaded');
		wrap.querySelector('.cm-media-placeholder')?.remove();
	};

	const finishBroken = () => {
		if (timer != null) {
			window.clearTimeout(timer);
			timer = null;
		}
		wrap.classList.remove('cm-media-loading');
		wrap.classList.add('cm-media-broken');
		wrap.dataset.alt = img.alt || w().brokenImage;
		wrap.querySelector('.cm-media-placeholder')?.remove();
	};

	let timer: number | null = null;
	if (img.complete) {
		if (img.naturalWidth > 0) finishLoaded();
		else finishBroken();
		return;
	}

	// Local/cached images finish in a few milliseconds; delay the skeleton
	// slightly so cached swaps never flicker.
	timer = window.setTimeout(() => {
		timer = null;
		if (img.complete) {
			if (img.naturalWidth > 0) finishLoaded();
			else finishBroken();
			return;
		}
		wrap.classList.add('cm-media-loading');
		if (!wrap.querySelector('.cm-media-placeholder')) {
			const ph = document.createElement('span');
			ph.className = 'cm-media-placeholder';
			ph.setAttribute('aria-hidden', 'true');
			ph.innerHTML =
				'<span class="cm-media-placeholder-icon">' +
				'<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">' +
				'<rect x="3" y="4" width="18" height="16" rx="3"/>' +
				'<circle cx="9" cy="10" r="1.5"/>' +
				'<path d="m21 16-5-5-4 4-2-2-5 5"/>' +
				'</svg></span>';
			const text = document.createElement('span');
			text.className = 'cm-media-placeholder-label';
			text.textContent = label;
			ph.appendChild(text);
			wrap.appendChild(ph);
		}
	}, 50);

	img.addEventListener('load', finishLoaded, { once: true });
	img.addEventListener('error', finishBroken, { once: true });
}

function scanMediaImages(root: ParentNode) {
	const imgs = root.querySelectorAll('.cm-media > img');
	for (const node of imgs) wireMediaImage(node as HTMLImageElement);
}

const mediaObserver = new MutationObserver((mutations) => {
	for (const m of mutations) {
		for (const added of m.addedNodes) {
			if (!(added instanceof HTMLElement)) continue;
			if (added.tagName === 'IMG' && added.closest('.cm-media')) {
				wireMediaImage(added as HTMLImageElement);
			} else if (added.querySelectorAll) {
				scanMediaImages(added);
			}
		}
	}
});
mediaObserver.observe(host, { childList: true, subtree: true });

/** Replaces `ivy://res/<localId>` with `ivy://res/<remoteId>` in the active
 *  editor without stealing focus, moving the cursor or clobbering concurrent typing. */
function applyResourceNormalization(localId: string, remoteId: string) {
	if (!view) return;
	const needle = `ivy://res/${localId}`;
	const replacement = `ivy://res/${remoteId}`;
	const doc = view.state.doc.toString();
	if (!doc.includes(needle)) return;
	const changes: Array<{ from: number; to: number; insert: string }> = [];
	let idx = doc.indexOf(needle);
	while (idx !== -1) {
		changes.push({ from: idx, to: idx + needle.length, insert: replacement });
		idx = doc.indexOf(needle, idx + needle.length);
	}
	if (!changes.length) return;
	view.dispatch({
		changes,
		annotations: [Transaction.remote.of(true), Transaction.addToHistory.of(false)]
	});
	// Keep `lastEmitted` in sync; for an unlocked password-protected note, also
	// re-seal and emit so the server receives the normalized server ID.
	const updatedText = view.state.doc.toString();
	if (protection.plain() !== null) {
		const sealed = protection.edited(updatedText);
		lastEmitted = sealed;
		post({ type: 'change', id: noteId, body: sealed });
	} else {
		lastEmitted = updatedText;
	}
}

function flushPendingNormalizations() {
	if (!view || view.compositionStarted || !pendingNormalizations.length) return;
	const items = pendingNormalizations;
	pendingNormalizations = [];
	for (const item of items) applyResourceNormalization(item.localId, item.remoteId);
}

function preloadImage(src: string, timeoutMs = 80): Promise<void> {
	return new Promise((resolve) => {
		const img = new Image();
		let done = false;
		const finish = () => {
			if (done) return;
			done = true;
			window.clearTimeout(timer);
			resolve();
		};
		const timer = window.setTimeout(finish, timeoutMs);
		img.onload = finish;
		img.onerror = finish;
		img.src = src;
		if (img.complete) finish();
	});
}

/** Puts text that changed elsewhere into the editor with the minimal diff,
 *  so the cursor stays where it is. */
function replaceText(v: string) {
	if (!view) return;
	const cur = view.state.doc.toString();
	if (v === cur) return;
	let start = 0;
	while (start < cur.length && start < v.length && cur[start] === v[start]) start++;
	let endCur = cur.length;
	let endNew = v.length;
	while (endCur > start && endNew > start && cur[endCur - 1] === v[endNew - 1]) {
		endCur--;
		endNew--;
	}
	view.dispatch({ changes: { from: start, to: endCur, insert: v.slice(start, endNew) }, annotations: Transaction.remote.of(true) });
}

// Password-protected notes: the page holds the plaintext only while
// unlocked; the app only ever sees the sealed body.
const protection = new Protection({
	lockHost: host,
	show(text) {
		const state = EditorState.create({ doc: text, extensions: extensions(loadReadonly) });
		if (view) view.setState(state);
		else view = new EditorView({ state, parent: host });
		view.scrollDOM.scrollTop = 0;
	},
	hide() {
		view?.destroy();
		view = null;
	},
	replace: replaceText,
	text: () => view?.state.doc.toString() ?? null,
	emit(body) {
		lastEmitted = body;
		post({ type: 'change', id: noteId, body });
	},
	state: (s) => post({ type: 'protection', id: noteId, ...s }),
	readonly: () => !view || view.state.readOnly
});
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
		loadReadonly = !!p.readonly;
		userPlacedCursor = false;
		pendingNormalizations = [];
		if (p.fontSize) document.documentElement.style.setProperty('--editor-size', `${p.fontSize}px`);
		renderBacklinks([]);
		// The editor, or the lock panel of a protected note.
		protection.load(p.body);
		scanMediaImages(host);
		document.scrollingElement?.scrollTo(0, 0);
		lastTop = -1;
		reportTop();
		if (p.focus && !protection.isLocked) window.ivy.focus(true);
	},

	/** A body that changed elsewhere (sync, merge). Applies the minimal diff
	 *  so the cursor stays where it is. */
	setBody(id: string, v: string) {
		if (id !== noteId || v === lastEmitted) return;
		lastEmitted = v;
		protection.external(v);
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

	/** Inserts attachment Markdown at the latest cursor position (or the end of
	 *  the note if the user has not placed a cursor yet), without forcing edit
	 *  mode or jumping to the start of the document. */
	insertAttachment(text: string) {
		if (!view || view.state.readOnly) return;
		const { state } = view;
		const wasFocused = view.hasFocus;
		const r = !userPlacedCursor && state.doc.length > 0
			? { from: state.doc.length, to: state.doc.length }
			: state.selection.main;
		let insert = text;
		const line = state.doc.lineAt(r.from);
		if (r.from > line.from) insert = '\n' + insert;
		const hasFollowingNewline = r.to < state.doc.length && state.sliceDoc(r.to, r.to + 1) === '\n';
		let nextAnchor: number;
		if (hasFollowingNewline) {
			nextAnchor = r.from + insert.length + 1;
		} else {
			insert += '\n';
			nextAnchor = r.from + insert.length;
		}
		userPlacedCursor = true;
		view.dispatch({
			changes: { from: r.from, to: r.to, insert },
			selection: { anchor: nextAnchor },
			scrollIntoView: true,
			userEvent: 'input'
		});
		if (wasFocused) view.focus();
	},

	/** Normalizes `ivy://res/<localId>` -> `ivy://res/<remoteId>` after a
	 *  background upload completes, keeping cursor, scroll and focus untouched. */
	normalizeResource(localId: string, remoteId: string, kind: string) {
		if (kind) kinds[remoteId] = kind;
		const apply = () => {
			if (!view) return;
			if (view.compositionStarted) {
				pendingNormalizations.push({ localId, remoteId });
				return;
			}
			applyResourceNormalization(localId, remoteId);
		};
		if (kind === 'image') {
			void preloadImage(resource(remoteId)).then(apply);
		} else {
			apply();
		}
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
		// An unlocked protected note copies as its text; a locked one as a notice.
		if (md === lastEmitted) md = protection.plain() ?? md;
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
		userPlacedCursor = true;
		view.focus();
		if (atEnd) view.dispatch({ selection: { anchor: view.state.doc.length }, scrollIntoView: true });
	},

	/** Jumps to a 0-based line (the outline), its heading at the top. */
	scrollToLine(line: number, focus = false) {
		if (!view) return;
		const l = view.state.doc.line(Math.min(Math.max(1, line + 1), view.state.doc.lines));
		if (focus) userPlacedCursor = true;
		view.dispatch({ selection: { anchor: l.from }, effects: EditorView.scrollIntoView(l.from, { y: 'start', yMargin: 24 }) });
		if (focus) view.focus();
	},

	/** Formatting from the native toolbar. */
	command(name: string) {
		switch (name) {
			case 'protect': void protection.protect(); return;
			case 'unprotect': void protection.unprotect(); return;
			case 'changePassword': void protection.changePassword(); return;
			case 'lock': protection.lock(); return;
		}
		if (!view) return;
		switch (name) {
			case 'due': openDuePicker(view); return;
			case 'insert': openInsertMenu(view); return;
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
