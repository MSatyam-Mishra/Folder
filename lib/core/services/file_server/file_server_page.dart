import 'dart:convert';

/// The app's colour scheme as CSS custom properties (`--background`, …) for
/// light and dark pages.
class WebTheme {
  const WebTheme({required this.light, required this.dark});

  final Map<String, String> light;
  final Map<String, String> dark;

  /// shadcn's zinc scheme, for tests and previews.
  static const fallback = WebTheme(
    light: {
      'background': '#ffffff',
      'foreground': '#09090b',
      'card': '#ffffff',
      'card-foreground': '#09090b',
      'popover': '#ffffff',
      'popover-foreground': '#09090b',
      'primary': '#18181b',
      'primary-foreground': '#fafafa',
      'muted': '#f4f4f5',
      'muted-foreground': '#71717a',
      'accent': '#f4f4f5',
      'accent-foreground': '#18181b',
      'destructive': '#ef4444',
      'border': '#e4e4e7',
      'input': '#e4e4e7',
      'ring': '#18181b',
    },
    dark: {
      'background': '#09090b',
      'foreground': '#fafafa',
      'card': '#09090b',
      'card-foreground': '#fafafa',
      'popover': '#09090b',
      'popover-foreground': '#fafafa',
      'primary': '#fafafa',
      'primary-foreground': '#18181b',
      'muted': '#27272a',
      'muted-foreground': '#a1a1aa',
      'accent': '#27272a',
      'accent-foreground': '#fafafa',
      'destructive': '#7f1d1d',
      'border': '#27272a',
      'input': '#27272a',
      'ring': '#d4d4d8',
    },
  );
}

/// How the page opens an entry.
enum EntryAction {
  /// A folder: navigate into it.
  browse,

  /// Images, video and audio: the in-page viewer.
  view,

  /// Something the browser displays itself (PDF, text): a new tab.
  tab,

  /// Everything else.
  download,
}

class PageEntry {
  const PageEntry({
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.modified,
    required this.icon,
    required this.iconDark,
    this.children,
    this.kind = 'file',
    this.action = EntryAction.download,
    this.thumbnail,
    this.fullImage,
  });

  final String name;
  final bool isDirectory;
  final int size;
  final DateTime modified;

  /// Icon ids for light and dark pages (often the same).
  final String icon;
  final String iconDark;

  /// Items in a folder, when counted.
  final int? children;

  /// `image`, `video`, `audio` or `file`.
  final String kind;
  final EntryAction action;

  /// Preview image URL (relative to the folder), if any.
  final String? thumbnail;

  /// Image the viewer shows, when not the file itself (formats browsers
  /// can't display, converted by the app).
  final String? fullImage;

  bool get isHidden => name.startsWith('.');

  String get href => Uri.encodeComponent(name) + (isDirectory ? '/' : '');
}

class Crumb {
  const Crumb(this.label, this.href);
  final String label;
  final String href;
}

// Like the default HtmlEscape, but leaves `/` alone (it's safe in text and
// quoted attributes, and URLs stay readable).
const _esc = HtmlEscape(
  HtmlEscapeMode(
    name: 'text-and-attributes',
    escapeLtGt: true,
    escapeQuot: true,
    escapeApos: true,
  ),
);
String _e(String s) => _esc.convert(s);

/// Shared `<head>`, header and footer around [body].
String _document({
  required String title,
  required String body,
  required WebTheme theme,
  required String assets,
  required String version,
  required String deviceName,
  String bodyAttributes = '',
}) {
  final css = StringBuffer(':root{');
  theme.light.forEach((k, v) => css.write('--$k:$v;'));
  css.write('}:root[data-mode=dark]{');
  theme.dark.forEach((k, v) => css.write('--$k:$v;'));
  css.write('}@media (prefers-color-scheme:dark){:root:not([data-mode]){');
  theme.dark.forEach((k, v) => css.write('--$k:$v;'));
  css.write('}}');

  return '''<!doctype html>
<html lang="en" class="no-js">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="${theme.light['background']}" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="${theme.dark['background']}" media="(prefers-color-scheme: dark)">
<meta name="robots" content="noindex, nofollow">
<title>${_e(title)}</title>
<link rel="icon" href="$assets/logo.svg?v=$version" type="image/svg+xml">
<link rel="preload" href="$assets/geist.ttf" as="font" type="font/ttf" crossorigin>
<style>$css</style>
<link rel="stylesheet" href="$assets/app.css?v=$version">
<script>(function(d){var p;try{p=localStorage.getItem('explorer.theme')}catch(e){}if(p!=='light'&&p!=='dark')p='system';d.dataset.pref=p;d.dataset.mode=p==='dark'||(p==='system'&&matchMedia('(prefers-color-scheme: dark)').matches)?'dark':'light';d.className='js'})(document.documentElement)</script>
</head>
<body$bodyAttributes>
$_sprite
<header class="topbar">
  <div class="topbar-inner container">
    <a class="brand" href="/">
      <img src="$assets/logo.svg?v=$version" alt="" width="28" height="28">
      <span class="brand-text"><strong>Folders</strong>${deviceName.isEmpty ? '' : '<small>${_e(deviceName)}</small>'}</span>
    </a>
    <span class="live" title="This page works while sharing is on in the app"><span class="dot"></span>Sharing</span>
    <span class="spacer"></span>
    <button class="btn btn-ghost btn-icon js-only" id="theme" type="button" aria-label="Theme">
      ${_icon('sun', 'when-light')}${_icon('moon', 'when-dark')}${_icon('monitor', 'when-system')}
    </button>
  </div>
</header>
$body
<footer>
  <div class="container">
    <span>Shared from Folders${deviceName.isEmpty ? '' : ' on ${_e(deviceName)}'}</span>
    <span>Anyone on this network can open this page while sharing is on.</span>
  </div>
</footer>
<script src="$assets/app.js?v=$version" defer></script>
</body>
</html>''';
}

/// A folder listing.
String renderDirectoryPage({
  required String title,
  required List<Crumb> crumbs,
  required List<PageEntry> entries,
  required bool uploads,
  required WebTheme theme,
  required String assets,
  required String version,
  required String deviceName,
}) {
  final folders = entries.where((e) => e.isDirectory && !e.isHidden).length;
  final files = entries.where((e) => !e.isDirectory && !e.isHidden).length;
  final hidden = entries.where((e) => e.isHidden).length;
  final bytes = entries
      .where((e) => !e.isDirectory && !e.isHidden)
      .fold<int>(0, (sum, e) => sum + e.size);
  final summary = [
    if (folders > 0) _count(folders, 'folder'),
    if (files > 0) _count(files, 'file'),
    if (files > 0) formatSize(bytes),
  ];
  final media = entries
      .where((e) => !e.isDirectory && (e.kind == 'image' || e.kind == 'video'))
      .length;

  final b = StringBuffer()
    ..write('<main class="container">')
    ..write('<nav class="crumbs" aria-label="Folders">');
  for (var i = 0; i < crumbs.length; i++) {
    final c = crumbs[i];
    final last = i == crumbs.length - 1;
    if (i > 0) b.write(_icon('chevron-right', 'sep'));
    b.write(
      '<a href="${_e(c.href)}"${last ? ' aria-current="page"' : ''}>'
      '${i == 0 ? _icon('house') : ''}<span>${_e(c.label)}</span></a>',
    );
  }
  b
    ..write('</nav>')
    ..write('<section class="page-head"><div class="page-title">')
    ..write('<h1>${_e(title)}</h1>')
    ..write(
      '<p class="summary"><span id="summary">'
      '${summary.isEmpty ? 'Empty folder' : summary.join(' · ')}</span>',
    );
  if (hidden > 0) {
    b.write(
      '<span class="js-only"> · ${_count(hidden, 'hidden item')} '
      '<button class="link" id="toggle-hidden" type="button">Show</button>'
      '</span>',
    );
  }
  b
    ..write('</p></div><div class="actions">')
    ..write(
      uploads
          ? '<button class="btn btn-primary js-only" id="upload-btn" type="button">'
                '${_icon('upload')}Upload</button>'
                '<input id="picker" type="file" multiple hidden>'
          : '',
    );
  if (entries.isNotEmpty) {
    b.write(
      '<a class="btn btn-outline" href="?zip" download>'
      '${_icon('folder-down')}Download all</a>',
    );
  }
  b.write('</div></section>');

  if (entries.isEmpty) {
    b.write(
      _emptyState(
        'folder-open',
        'This folder is empty',
        uploads
            ? 'Drop files here or use Upload to add some.'
            : 'Files added on the phone show up here after a refresh.',
      ),
    );
  } else {
    b
      ..write('<div class="toolbar js-only">')
      ..write(
        '<label class="search">${_icon('search')}'
        '<span class="sr-only">Search</span>'
        '<input class="input" id="q" type="search" placeholder="Search this folder" autocomplete="off" spellcheck="false">'
        '<kbd id="q-key" aria-hidden="true">/</kbd>'
        '<button class="search-clear" id="q-clear" type="button" aria-label="Clear search" hidden>${_icon('x')}</button>'
        '</label>',
      )
      ..write('<div class="toolbar-end">')
      ..write(
        '<span class="select">${_icon('arrow-up-down', 'lead')}'
        '<select id="sort" aria-label="Sort by">'
        '<option value="name">Name</option>'
        '<option value="date">Date modified</option>'
        '<option value="size">Size</option>'
        '<option value="type">Type</option>'
        '</select>${_icon('chevron-down', 'trail')}</span>',
      )
      ..write(
        '<button class="btn btn-outline btn-icon" id="sort-dir" type="button" aria-label="Sort direction">'
        '${_icon('arrow-down-narrow-wide', 'when-asc')}${_icon('arrow-down-wide-narrow', 'when-desc')}</button>',
      )
      ..write(
        '<div class="segmented" role="group" aria-label="View">'
        '<button type="button" data-view-btn="list" aria-pressed="true" title="List">${_icon('list')}</button>'
        '<button type="button" data-view-btn="grid" aria-pressed="false" title="Grid">${_icon('layout-grid')}</button>'
        '</div>',
      )
      ..write('</div></div>')
      ..write(
        '<section class="files" id="files" data-view="list" data-media="$media" data-count="${entries.length}">',
      )
      ..write(
        '<div class="files-head" role="presentation">'
        '<button type="button" data-sort="name">Name${_icon('arrow-up', 'dir')}</button>'
        '<button type="button" data-sort="size" class="end">Size${_icon('arrow-up', 'dir')}</button>'
        '<button type="button" data-sort="date">Modified${_icon('arrow-up', 'dir')}</button>'
        '<span></span></div>',
      )
      ..write('<div class="entries" id="entries">');
    for (final e in entries) {
      _writeEntry(b, e);
    }
    b
      ..write('</div></section>')
      ..write('<div id="no-match" hidden>')
      ..write(_emptyState('search-x', 'No matches', ''))
      ..write('</div>');
  }
  b.write('</main>');

  if (uploads) {
    b.write(
      '<div class="dropzone" id="dropzone" hidden><div class="dropzone-inner">'
      '<span class="badge-icon">${_icon('upload')}</span>'
      '<strong>Drop files to upload</strong>'
      '<span>They\'ll be saved to ${_e(title)}</span></div></div>',
    );
  }
  b.write(_viewer);

  return _document(
    title: '$title · Folders',
    body: b.toString(),
    theme: theme,
    assets: assets,
    version: version,
    deviceName: deviceName,
    bodyAttributes: ' data-upload="${uploads ? 1 : 0}"',
  );
}

void _writeEntry(StringBuffer b, PageEntry e) {
  final href = _e(e.href);
  final iconAttrs = e.icon == e.iconDark ? '' : ' has-dark';
  final meta = e.isDirectory
      ? (e.children == null ? 'Folder' : _count(e.children!, 'item'))
      : formatSize(e.size);
  final ext = e.isDirectory ? '' : _extension(e.name);
  final title = _e(e.name);
  // Split off the extension so long names shorten in the middle and keep it.
  final dot = e.isDirectory ? -1 : e.name.lastIndexOf('.');
  final (stem, extension) = dot > 0
      ? (e.name.substring(0, dot), e.name.substring(dot))
      : (e.name, '');
  b
    ..write(
      '<div class="entry" data-name="${_e(e.name)}" data-dir="${e.isDirectory ? 1 : 0}"'
      ' data-size="${e.isDirectory ? 0 : e.size}"'
      ' data-mtime="${e.modified.millisecondsSinceEpoch}" data-type="${_e(ext)}"'
      ' data-kind="${e.kind}" data-view="${e.action == EntryAction.view ? e.kind : ''}"'
      '${e.isHidden ? ' data-hidden="1"' : ''}'
      '${e.fullImage != null ? ' data-full="${_e(e.fullImage!)}"' : ''}>',
    )
    ..write(
      '<div class="main"><span class="thumb$iconAttrs">'
      '<img class="ic ic-light" src="${_e(e.icon)}" alt="" loading="lazy" decoding="async">',
    );
  if (e.icon != e.iconDark) {
    b.write(
      '<img class="ic ic-dark" src="${_e(e.iconDark)}" alt="" loading="lazy" decoding="async">',
    );
  }
  if (e.thumbnail != null) {
    b.write(
      '<img class="preview" src="${_e(e.thumbnail!)}" alt="" loading="lazy" decoding="async" onerror="this.remove()">',
    );
  }
  b.write('</span><span class="name">');
  switch (e.action) {
    case EntryAction.browse:
    case EntryAction.view:
      b.write('<a class="open" href="$href" title="$title">');
    case EntryAction.tab:
      b.write(
        '<a class="open" href="$href" title="$title" target="_blank" rel="noopener">',
      );
    case EntryAction.download:
      b.write('<a class="open" href="$href?download" title="$title" download>');
  }
  b
    ..write('<span class="stem">${_e(stem)}</span>')
    ..write(
      extension.isEmpty ? '' : '<span class="ext">${_e(extension)}</span>',
    )
    ..write('</a>')
    ..write(
      '<span class="meta"><span>${_e(meta)}</span>'
      '<span class="meta-date" data-t="${e.modified.millisecondsSinceEpoch}">${_date(e.modified)}</span></span>',
    )
    ..write('</span></div>')
    ..write('<span class="size">${_e(meta)}</span>')
    ..write(
      '<span class="date" data-t="${e.modified.millisecondsSinceEpoch}">${_date(e.modified)}</span>',
    )
    ..write('<span class="row-actions">');
  if (e.isDirectory) {
    b.write(
      '<a class="btn btn-ghost btn-icon" href="$href?zip" download title="Download as ZIP" aria-label="Download ${_e(e.name)} as ZIP">${_icon('folder-down')}</a>',
    );
  } else {
    b.write(
      '<a class="btn btn-ghost btn-icon" href="$href?download" download title="Download" aria-label="Download ${_e(e.name)}">${_icon('download')}</a>',
    );
  }
  b.write('</span></div>');
}

/// A page for errors (not found, no access, …).
String renderMessagePage({
  required int status,
  required String title,
  required String message,
  required WebTheme theme,
  required String assets,
  required String version,
  required String deviceName,
}) {
  final body =
      '<main class="container">'
      '${_emptyState(status == 404 ? 'file-question' : 'circle-alert', title, message, action: '<a class="btn btn-outline" href="/">${_icon('house')}Back to the shared folder</a>')}'
      '</main>';
  return _document(
    title: '$title · Folders',
    body: body,
    theme: theme,
    assets: assets,
    version: version,
    deviceName: deviceName,
  );
}

String _emptyState(
  String icon,
  String title,
  String text, {
  String action = '',
}) =>
    '<div class="empty"><span class="badge-icon">${_icon(icon)}</span>'
    '<h2>${_e(title)}</h2><p>${_e(text)}</p>$action</div>';

const _viewer = '''
<div class="viewer" id="viewer" role="dialog" aria-modal="true" aria-labelledby="v-name" tabindex="-1" hidden>
  <div class="viewer-bar">
    <div class="viewer-title"><strong id="v-name"></strong><span id="v-count"></span></div>
    <a class="vbtn" id="v-open" target="_blank" rel="noopener" title="Open in new tab" aria-label="Open in new tab"><svg class="i" aria-hidden="true"><use href="#i-external-link"/></svg></a>
    <a class="vbtn" id="v-dl" download title="Download" aria-label="Download"><svg class="i" aria-hidden="true"><use href="#i-download"/></svg></a>
    <button class="vbtn" id="v-close" type="button" title="Close (Esc)" aria-label="Close"><svg class="i" aria-hidden="true"><use href="#i-x"/></svg></button>
  </div>
  <div class="viewer-stage" id="v-stage"></div>
  <button class="vnav prev" id="v-prev" type="button" aria-label="Previous"><svg class="i" aria-hidden="true"><use href="#i-chevron-left"/></svg></button>
  <button class="vnav next" id="v-next" type="button" aria-label="Next"><svg class="i" aria-hidden="true"><use href="#i-chevron-right"/></svg></button>
</div>''';

String _icon(String id, [String cls = '']) =>
    '<svg class="i${cls.isEmpty ? '' : ' $cls'}" aria-hidden="true"><use href="#i-$id"/></svg>';

String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
}

/// Shown until the script formats dates in the viewer's locale.
String _date(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

/// `1.2 MB`, matching the app.
String formatSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

/// Lucide icons (ISC licence), used through `<use href="#i-name">`.
const _sprite =
    '''<svg width="0" height="0" style="position:absolute" aria-hidden="true"><defs>
<symbol id="i-search" viewBox="0 0 24 24"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></symbol>
<symbol id="i-search-x" viewBox="0 0 24 24"><path d="m13.5 8.5-5 5"/><path d="m8.5 8.5 5 5"/><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></symbol>
<symbol id="i-x" viewBox="0 0 24 24"><path d="M18 6 6 18"/><path d="m6 6 12 12"/></symbol>
<symbol id="i-house" viewBox="0 0 24 24"><path d="M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8"/><path d="M3 10a2 2 0 0 1 .709-1.528l7-5.999a2 2 0 0 1 2.582 0l7 5.999A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></symbol>
<symbol id="i-chevron-right" viewBox="0 0 24 24"><path d="m9 18 6-6-6-6"/></symbol>
<symbol id="i-chevron-left" viewBox="0 0 24 24"><path d="m15 18-6-6 6-6"/></symbol>
<symbol id="i-chevron-down" viewBox="0 0 24 24"><path d="m6 9 6 6 6-6"/></symbol>
<symbol id="i-download" viewBox="0 0 24 24"><path d="M12 15V3"/><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/></symbol>
<symbol id="i-upload" viewBox="0 0 24 24"><path d="M12 3v12"/><path d="m17 8-5-5-5 5"/><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/></symbol>
<symbol id="i-folder-down" viewBox="0 0 24 24"><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/><path d="M12 10v6"/><path d="m15 13-3 3-3-3"/></symbol>
<symbol id="i-folder-open" viewBox="0 0 24 24"><path d="m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"/></symbol>
<symbol id="i-file-question" viewBox="0 0 24 24"><path d="M12 17h.01"/><path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z"/><path d="M9.1 9a3 3 0 0 1 5.82 1c0 2-3 3-3 3"/></symbol>
<symbol id="i-circle-alert" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><path d="M12 8v4"/><path d="M12 16h.01"/></symbol>
<symbol id="i-circle-check" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/></symbol>
<symbol id="i-sun" viewBox="0 0 24 24"><circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/></symbol>
<symbol id="i-moon" viewBox="0 0 24 24"><path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/></symbol>
<symbol id="i-monitor" viewBox="0 0 24 24"><rect width="20" height="14" x="2" y="3" rx="2"/><path d="M8 21h8"/><path d="M12 17v4"/></symbol>
<symbol id="i-list" viewBox="0 0 24 24"><path d="M3 12h.01"/><path d="M3 18h.01"/><path d="M3 6h.01"/><path d="M8 12h13"/><path d="M8 18h13"/><path d="M8 6h13"/></symbol>
<symbol id="i-layout-grid" viewBox="0 0 24 24"><rect width="7" height="7" x="3" y="3" rx="1"/><rect width="7" height="7" x="14" y="3" rx="1"/><rect width="7" height="7" x="14" y="14" rx="1"/><rect width="7" height="7" x="3" y="14" rx="1"/></symbol>
<symbol id="i-arrow-up-down" viewBox="0 0 24 24"><path d="m21 16-4 4-4-4"/><path d="M17 20V4"/><path d="m3 8 4-4 4 4"/><path d="M7 4v16"/></symbol>
<symbol id="i-arrow-up" viewBox="0 0 24 24"><path d="m5 12 7-7 7 7"/><path d="M12 19V5"/></symbol>
<symbol id="i-arrow-down-narrow-wide" viewBox="0 0 24 24"><path d="m3 16 4 4 4-4"/><path d="M7 20V4"/><path d="M11 4h4"/><path d="M11 8h7"/><path d="M11 12h10"/></symbol>
<symbol id="i-arrow-down-wide-narrow" viewBox="0 0 24 24"><path d="m3 16 4 4 4-4"/><path d="M7 20V4"/><path d="M11 4h10"/><path d="M11 8h7"/><path d="M11 12h4"/></symbol>
<symbol id="i-external-link" viewBox="0 0 24 24"><path d="M15 3h6v6"/><path d="M10 14 21 3"/><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/></symbol>
<symbol id="i-refresh-cw" viewBox="0 0 24 24"><path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/></symbol>
</defs></svg>''';
