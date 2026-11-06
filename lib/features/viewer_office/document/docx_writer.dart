import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../common/office_package.dart';
import '../common/office_xml.dart';
import 'doc_model.dart';

const _nsW = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _nsR =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _nsWp =
    'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing';
const _relBase =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

/// Writes [model] as DOCX.
///
/// With [original] (the source DOCX bytes) only the main document part (and
/// numbering/relationships when needed) is rewritten; every other part —
/// styles, headers, footers, media, settings, custom XML — is kept as is.
/// Without it a fresh, minimal package is produced.
Uint8List writeDocx(DocModel model, {Uint8List? original}) {
  if (original != null && model.docx != null) {
    final pkg = OfficePackage.decode(original);
    return _DocxWriter(model, pkg, preserve: true).writeIntoPackage();
  }
  return _DocxWriter(
    model,
    OfficePackage.empty(),
    preserve: false,
  ).writeFresh();
}

const _pPrOrder = [
  'pStyle',
  'keepNext',
  'keepLines',
  'pageBreakBefore',
  'framePr',
  'widowControl',
  'numPr',
  'suppressLineNumbers',
  'pBdr',
  'shd',
  'tabs',
  'suppressAutoHyphens',
  'kinsoku',
  'wordWrap',
  'overflowPunct',
  'topLinePunct',
  'autoSpaceDE',
  'autoSpaceDN',
  'bidi',
  'adjustRightInd',
  'snapToGrid',
  'spacing',
  'ind',
  'contextualSpacing',
  'mirrorIndents',
  'suppressOverlap',
  'jc',
  'textDirection',
  'textAlignment',
  'textboxTightWrap',
  'outlineLvl',
  'divId',
  'cnfStyle',
  '*',
  'rPr',
  'sectPr',
  'pPrChange',
];

const _rPrOrder = [
  'rStyle',
  'rFonts',
  'b',
  'bCs',
  'i',
  'iCs',
  'caps',
  'smallCaps',
  'strike',
  'dstrike',
  'outline',
  'shadow',
  'emboss',
  'imprint',
  'noProof',
  'snapToGrid',
  'vanish',
  'webHidden',
  'color',
  'spacing',
  'w',
  'kern',
  'position',
  'sz',
  'szCs',
  'highlight',
  'u',
  'effect',
  'bdr',
  'shd',
  'fitText',
  'vertAlign',
  'rtl',
  'cs',
  'em',
  'lang',
  'eastAsianLayout',
  'specVanish',
  'oMath',
  '*',
  'rPrChange',
];

/// Sorts element children into schema order (unknown ones go to `*`).
void _sortChildren(XmlElement e, List<String> order) {
  final star = order.indexOf('*');
  int rank(XmlElement n) {
    final i = order.indexOf(n.name.local);
    return i < 0 ? star : i;
  }

  final kids = e.children.whereType<XmlElement>().toList();
  final indexed = [for (var i = 0; i < kids.length; i++) (i, kids[i])];
  indexed.sort((a, b) {
    final c = rank(a.$2).compareTo(rank(b.$2));
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  e.children.clear();
  for (final k in indexed) {
    e.children.add(k.$2);
  }
}

XmlElement? _parseFragment(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    return XmlDocument.parse(raw).rootElement.copy();
  } catch (_) {
    return null;
  }
}

XmlElement _w(
  String local, [
  Map<String, String> attrs = const {},
  List<XmlNode> children = const [],
]) {
  return XmlElement(XmlName(local, 'w'), [
    for (final e in attrs.entries) XmlAttribute(XmlName(e.key, 'w'), e.value),
  ], children);
}

void _removeAll(XmlElement e, Set<String> locals) {
  e.children.removeWhere(
    (n) => n is XmlElement && locals.contains(n.name.local),
  );
}

XmlElement? _childEl(XmlElement e, String local) => Ox.child(e, local);

const _namedHighlights = {
  0xFFFFFF00: 'yellow',
  0xFF00FF00: 'green',
  0xFF00FFFF: 'cyan',
  0xFFFF00FF: 'magenta',
  0xFF0000FF: 'blue',
  0xFFFF0000: 'red',
  0xFF000080: 'darkBlue',
  0xFF008080: 'darkCyan',
  0xFF008000: 'darkGreen',
  0xFF800080: 'darkMagenta',
  0xFF800000: 'darkRed',
  0xFF808000: 'darkYellow',
  0xFF808080: 'darkGray',
  0xFFC0C0C0: 'lightGray',
  0xFF000000: 'black',
  0xFFFFFFFF: 'white',
};

String _tw(double pt) => Units.toTwips(pt).toString();

class _NewRel {
  _NewRel(this.id, this.type, this.target, {this.external = false});
  final String id;
  final String type;
  final String target;
  final bool external;
}

class _DocxWriter {
  _DocxWriter(this.model, this.pkg, {required this.preserve});

  final DocModel model;
  final OfficePackage pkg;
  final bool preserve;

  late final String mainPart;
  final Map<String, String> _urlToRel = {};
  final List<_NewRel> _newRels = [];
  int _relNo = 1;
  int _docPrId = 5000;
  int _imageNo = 1;
  final Map<String, String> _imageRel = {};

  // Numbering.
  String? _bulletNumId;
  String? _orderedAbsId;
  String? _bulletAbsId;
  final List<(String numId, String absId, bool restart)> _newNums = [];
  int _nextNumId = 1;
  int _nextAbsId = 0;
  String? _currentOrderedNum;

  /// The original main part, for copying untouched body elements verbatim.
  String? _source;
  final Set<DocSourceSpan> _claimed = {};

  // ---------------------------------------------------------------------------

  Uint8List writeIntoPackage() {
    final info = model.docx!;
    mainPart = info.mainPart;
    final docText = pkg.text(mainPart);
    if (docText == null) {
      throw const FormatException('Missing main document part');
    }
    _source = docText;

    // Existing relationships.
    final rels = pkg.rels(mainPart);
    for (final r in rels) {
      final m = RegExp(r'(\d+)$').firstMatch(r.id);
      if (m != null) {
        final n = int.parse(m.group(1)!);
        if (n >= _relNo) _relNo = n + 1;
      }
      if (r.kind == 'hyperlink') _urlToRel.putIfAbsent(r.target, () => r.id);
    }
    _scanNumbering();

    final body = _body(model.blocks, info.bodySectPr);

    // Splice the new body into the original document markup.
    final open = RegExp(
      r'<([A-Za-z_][\w.\-]*:)?body(\s[^>]*)?>',
    ).firstMatch(docText);
    final closeIdx = docText.lastIndexOf(
      RegExp(r'</([A-Za-z_][\w.\-]*:)?body>'),
    );
    if (open == null || closeIdx < open.end) {
      throw const FormatException('Unexpected document structure');
    }
    var head = docText.substring(0, open.end);
    head = _ensureRootNamespaces(head);
    final out = StringBuffer()
      ..write(head)
      ..write(body)
      ..write(docText.substring(closeIdx));
    pkg.putText(mainPart, out.toString());

    _writeNumbering();
    _writeRels();
    return pkg.encode();
  }

  String _ensureRootNamespaces(String head) {
    final root = RegExp(
      r'<([A-Za-z_][\w.\-]*:)?document\b[^>]*>',
    ).firstMatch(head);
    if (root == null) return head;
    var tag = root.group(0)!;
    final adds = <String>[];
    if (!tag.contains('xmlns:w="$_nsW"')) adds.add('xmlns:w="$_nsW"');
    if (!tag.contains('xmlns:r="$_nsR"')) adds.add('xmlns:r="$_nsR"');
    if (!tag.contains('xmlns:wp="$_nsWp"')) adds.add('xmlns:wp="$_nsWp"');
    if (adds.isEmpty) return head;
    // Only add prefixes that aren't bound to something else already.
    final filtered = adds.where((a) {
      final prefix = a.substring(0, a.indexOf('='));
      return !tag.contains('$prefix=');
    }).toList();
    if (filtered.isEmpty) return head;
    final closing = tag.endsWith('/>') ? 2 : 1;
    tag =
        '${tag.substring(0, tag.length - closing)} ${filtered.join(' ')}${tag.substring(tag.length - closing)}';
    return head.replaceRange(root.start, root.end, tag);
  }

  Uint8List writeFresh() {
    mainPart = 'word/document.xml';
    _relNo = 3; // rId1 styles, rId2 numbering
    _nextAbsId = 0;
    _nextNumId = 1;
    final body = _body(model.blocks, _sectPrXml(model.page, null));
    final doc = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write(
        '<w:document xmlns:w="$_nsW" xmlns:r="$_nsR" xmlns:wp="$_nsWp" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">',
      )
      ..write('<w:body>')
      ..write(body)
      ..write('</w:body></w:document>');
    pkg.putText(mainPart, doc.toString());
    pkg.putText('word/styles.xml', _freshStyles());
    pkg.putText('word/numbering.xml', _freshNumbering());

    final rels = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write(
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
      )
      ..write(
        '<Relationship Id="rId1" Type="$_relBase/styles" Target="styles.xml"/>',
      )
      ..write(
        '<Relationship Id="rId2" Type="$_relBase/numbering" Target="numbering.xml"/>',
      );
    for (final r in _newRels) {
      rels.write(
        '<Relationship Id="${r.id}" Type="${xmlEscape(r.type)}" '
        'Target="${xmlEscape(r.target)}"${r.external ? ' TargetMode="External"' : ''}/>',
      );
    }
    rels.write('</Relationships>');
    pkg.putText('word/_rels/document.xml.rels', rels.toString());

    final exts = <String>{};
    for (final name in pkg.order) {
      if (name.startsWith('word/media/')) {
        exts.add(name.substring(name.lastIndexOf('.') + 1));
      }
    }
    final ct = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write(
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
      )
      ..write(
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
      )
      ..write('<Default Extension="xml" ContentType="application/xml"/>');
    for (final e in exts) {
      ct.write(
        '<Default Extension="$e" ContentType="${ContentTypes.mimeForExtension(e) ?? 'application/octet-stream'}"/>',
      );
    }
    ct
      ..write(
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>',
      )
      ..write(
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>',
      )
      ..write(
        '<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>',
      )
      ..write(
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>',
      )
      ..write(
        '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>',
      )
      ..write('</Types>');
    pkg.putText(ContentTypes.path, ct.toString());
    pkg.putText(
      '_rels/.rels',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rId1" Type="$_relBase/officeDocument" Target="word/document.xml"/>'
          '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
          '<Relationship Id="rId3" Type="$_relBase/extended-properties" Target="docProps/app.xml"/>'
          '</Relationships>',
    );
    final now = DateTime.now().toUtc().toIso8601String().split('.').first;
    pkg.putText(
      'docProps/core.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
          'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
          'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
          '<dc:title>${xmlEscape(model.title ?? '')}</dc:title>'
          '<dcterms:created xsi:type="dcterms:W3CDTF">${now}Z</dcterms:created>'
          '<dcterms:modified xsi:type="dcterms:W3CDTF">${now}Z</dcterms:modified>'
          '</cp:coreProperties>',
    );
    pkg.putText(
      'docProps/app.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
          '<Application>Folders</Application></Properties>',
    );
    // Content types first, as Word itself writes it.
    pkg.order
      ..remove(ContentTypes.path)
      ..insert(0, ContentTypes.path);
    return pkg.encode();
  }

  // ---------------------------------------------------------------------------
  // Body

  String _body(List<DocBlock> blocks, String? finalSectPr) {
    final sb = StringBuffer();
    // Body elements whose blocks are all present and unedited are copied
    // from the original part as they were.
    final verbatim = <int, (int, DocSourceSpan)>{};
    final covered = <int>{};
    for (var i = 0; i < blocks.length; i++) {
      final v = _verbatimRun(blocks, i);
      if (v == null) continue;
      verbatim[i] = v;
      _claimed.add(v.$2);
      for (var k = i; k < v.$1; k++) {
        covered.add(k);
      }
      i = v.$1 - 1;
    }

    final leadingBreak = <int>{};
    final attachSect = <int, String>{};
    final skip = <int>{};
    for (var i = 0; i < blocks.length; i++) {
      if (covered.contains(i)) continue;
      final b = blocks[i];
      if (b is DocPageBreak) {
        final next = i + 1 < blocks.length ? blocks[i + 1] : null;
        if (next is DocParagraph && !covered.contains(i + 1)) {
          if (next.pageBreakBefore) {
            skip.add(i); // the paragraph starts a page anyway
          } else if (b.joinNext) {
            // A break inside the paragraph, before its text. A break that
            // was a paragraph of its own stays one.
            leadingBreak.add(i + 1);
            skip.add(i);
          }
        }
      } else if (b is DocSectionBreak) {
        final xml = b.raw ?? _sectPrXml(b.page, b.newPage);
        var j = i - 1;
        while (j >= 0 && blocks[j] is DocFrame) {
          j--;
        }
        if (j >= 0 &&
            blocks[j] is DocParagraph &&
            !covered.contains(j) &&
            !attachSect.containsKey(j)) {
          attachSect[j] = xml;
          skip.add(i);
        }
      }
    }
    for (var i = 0; i < blocks.length; i++) {
      final v = verbatim[i];
      if (v != null) {
        final (end, span) = v;
        sb.write(_source!.substring(span.start, span.end));
        for (var k = i; k < end; k++) {
          final x = blocks[k];
          if (x is DocTable) {
            _currentOrderedNum = null;
          } else if (x is DocParagraph) {
            final l = x.list;
            if (l != null && l.ordered) {
              _currentOrderedNum = l.numId;
            } else if (l == null && !x.isEmpty) {
              _currentOrderedNum = null;
            }
          }
        }
        i = end - 1;
        continue;
      }
      if (skip.contains(i)) continue;
      final b = blocks[i];
      switch (b) {
        case DocParagraph():
          if (b.list == null || !b.list!.ordered) {
            if (b.list == null && !b.isEmpty) _currentOrderedNum = null;
          }
          sb.write(
            _paragraph(
              b,
              leadingPageBreak: leadingBreak.contains(i),
              sectPr: attachSect[i],
            ),
          );
        case DocTable():
          _currentOrderedNum = null;
          sb.write(_table(b));
        case DocPageBreak():
          sb.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
        case DocSectionBreak():
          sb.write(
            '<w:p><w:pPr>${b.raw ?? _sectPrXml(b.page, b.newPage)}</w:pPr></w:p>',
          );
        case DocFrame():
          break;
      }
    }
    if (finalSectPr != null) sb.write(finalSectPr);
    return sb.toString();
  }

  /// When the blocks from [i] on are exactly the blocks one original body
  /// element produced (all present, in order, unedited), returns the index
  /// after them and the element's span.
  (int, DocSourceSpan)? _verbatimRun(List<DocBlock> blocks, int i) {
    final source = _source;
    final span = blocks[i].source;
    if (!preserve ||
        source == null ||
        span == null ||
        blocks[i].sourcePart != 0 ||
        _claimed.contains(span)) {
      return null;
    }
    if (span.start < 0 ||
        span.end > source.length ||
        span.end <= span.start ||
        source.codeUnitAt(span.start) != 0x3C ||
        source.codeUnitAt(span.end - 1) != 0x3E) {
      return null; // not the package the model was parsed from
    }
    var part = 0;
    var j = i;
    while (j < blocks.length && part < span.parts) {
      final b = blocks[j];
      if (b is DocFrame) {
        j++;
        continue;
      }
      if (!identical(b.source, span) || b.sourcePart != part) return null;
      if (b is DocParagraph && !_unedited(b)) return null;
      part++;
      j++;
    }
    return part == span.parts ? (j, span) : null;
  }

  /// Whether [p] still has exactly the content and paragraph formatting it
  /// was parsed with.
  static bool _unedited(DocParagraph p) {
    final o = p.origin;
    if (o == null) return true; // parsed, never edited
    if (o.headingLevel != p.headingLevel ||
        o.align != p.align ||
        o.rtl != p.rtl ||
        (o.list == null) != (p.list == null) ||
        (o.indentLeft - p.indentLeft).abs() > 0.05 ||
        (o.firstLine - p.firstLine).abs() > 0.05) {
      return false;
    }
    final ol = o.list, pl = p.list;
    if (ol != null && (ol.ordered != pl!.ordered || ol.level != pl.level)) {
      return false;
    }
    final a = [
      for (final i in o.inlines)
        if (i is! DocText || i.text.isNotEmpty) i,
    ];
    final b = [
      for (final i in p.inlines)
        if (i is! DocText || i.text.isNotEmpty) i,
    ];
    if (a.length != b.length) return false;
    for (var k = 0; k < a.length; k++) {
      final x = a[k], y = b[k];
      if (x is DocText && y is DocText) {
        if (x.text != y.text || x.style != y.style || x.link != y.link) {
          return false;
        }
      } else if (!identical(x, y)) {
        return false;
      }
    }
    return true;
  }

  String _sectPrXml(DocPageSetup p, bool? newPage) {
    final type = newPage == null
        ? ''
        : '<w:type w:val="${newPage ? 'nextPage' : 'continuous'}"/>';
    return '<w:sectPr>$type<w:pgSz w:w="${_tw(p.width)}" w:h="${_tw(p.height)}"'
        '${p.width > p.height ? ' w:orient="landscape"' : ''}/>'
        '<w:pgMar w:top="${_tw(p.marginTop)}" w:right="${_tw(p.marginRight)}" '
        'w:bottom="${_tw(p.marginBottom)}" w:left="${_tw(p.marginLeft)}" '
        'w:header="${_tw(p.headerDistance)}" w:footer="${_tw(p.footerDistance)}" w:gutter="0"/>'
        '<w:cols w:space="720"/></w:sectPr>';
  }

  DocRunStyle _wordBase(DocParagraph p) {
    final h = p.headingLevel;
    return h == null
        ? model.baseStyle
        : (model.headingStyles[h] ?? model.baseStyle);
  }

  String _paragraph(
    DocParagraph p, {
    bool leadingPageBreak = false,
    String? sectPr,
  }) {
    final pPr = _pPr(p, sectPr);
    final sb = StringBuffer('<w:p>');
    if (pPr != null) sb.write(pPr);
    if (leadingPageBreak) sb.write('<w:r><w:br w:type="page"/></w:r>');
    final base = _wordBase(p);
    String? openLink;
    for (final i in p.inlines) {
      final link = i is DocText ? i.link : null;
      if (link != openLink) {
        if (openLink != null) sb.write('</w:hyperlink>');
        if (link != null) sb.write(_hyperlinkOpen(link));
        openLink = link;
      }
      switch (i) {
        case DocText():
          sb.write(_run(i, base));
        case DocImage():
          sb.write(i.raw != null && preserve ? i.raw! : _drawing(i));
        case DocObject():
          if (i.raw != null && preserve) {
            sb.write(i.raw);
          } else if ((i.displayText ?? '').isNotEmpty) {
            sb.write(_run(DocText(i.displayText!, i.style), base));
          }
      }
    }
    if (openLink != null) sb.write('</w:hyperlink>');
    sb.write('</w:p>');
    return sb.toString();
  }

  String _hyperlinkOpen(String link) {
    if (link.startsWith('#')) {
      return '<w:hyperlink w:anchor="${xmlEscape(link.substring(1))}" w:history="1">';
    }
    final id = _urlToRel.putIfAbsent(link, () {
      final id = 'rId${_relNo++}';
      _newRels.add(_NewRel(id, '$_relBase/hyperlink', link, external: true));
      return id;
    });
    return '<w:hyperlink r:id="$id" w:history="1">';
  }

  String? _pPr(DocParagraph p, String? sectPr) {
    final o = p.origin;
    final raw = preserve ? p.raw : null;
    final el = _parseFragment(raw) ?? _w('pPr');
    final rawHadNumPr = _childEl(el, 'numPr') != null;
    final explicit = !preserve || raw == null;

    // Style.
    final normal = model.docx?.normalStyleId ?? 'Normal';
    String? styleId = p.styleId;
    if (!preserve) {
      styleId = p.headingLevel != null ? 'Heading${p.headingLevel}' : null;
    }
    if (explicit || o == null || o.styleId != p.styleId || !preserve) {
      _removeAll(el, {'pStyle'});
      if (styleId != null && styleId != normal) {
        el.children.add(_w('pStyle', {'val': styleId}));
      }
    }

    // Numbering.
    final list = p.list;
    final listChanged =
        o == null ||
        (o.list == null) != (list == null) ||
        (list != null &&
            (o.list!.ordered != list.ordered || o.list!.level != list.level));
    // Untouched non-list paragraphs keep their numPr — including
    // `numId 0`, which switches off numbering inherited from the style.
    if (explicit || listChanged || (list != null && list.numId == null)) {
      _removeAll(el, {'numPr'});
      if (list != null) {
        final numId = _numIdFor(list);
        el.children.add(
          _w('numPr', {}, [
            _w('ilvl', {'val': '${list.level.clamp(0, 8)}'}),
            _w('numId', {'val': numId}),
          ]),
        );
      } else if (o?.list != null && !rawHadNumPr && preserve) {
        // Numbering came from the paragraph style: switch it off.
        el.children.add(
          _w('numPr', {}, [
            _w('numId', {'val': '0'}),
          ]),
        );
      }
    } else if (list != null) {
      _noteExistingNum(list);
    }

    // Alignment.
    if (explicit || o == null || o.align != p.align) {
      _removeAll(el, {'jc'});
      if (p.align != DocAlign.left || (o != null && o.align != DocAlign.left)) {
        el.children.add(
          _w('jc', {
            'val': switch (p.align) {
              DocAlign.left => 'left',
              DocAlign.center => 'center',
              DocAlign.right => 'right',
              DocAlign.justify => 'both',
            },
          }),
        );
      }
    }

    // Indentation.
    final indentChanged =
        o == null ||
        (o.indentLeft - p.indentLeft).abs() > 0.05 ||
        (o.firstLine - p.firstLine).abs() > 0.05;
    if (explicit || indentChanged) {
      _removeAll(el, {'ind'});
      final listDefined =
          list != null && (o == null || listChanged || !preserve);
      if (!listDefined &&
          (p.indentLeft != 0 ||
              p.firstLine != 0 ||
              p.indentRight != 0 ||
              (o != null && preserve))) {
        final attrs = <String, String>{'left': _tw(p.indentLeft)};
        if (p.indentRight != 0) attrs['right'] = _tw(p.indentRight);
        if (p.firstLine > 0) attrs['firstLine'] = _tw(p.firstLine);
        if (p.firstLine < 0) attrs['hanging'] = _tw(-p.firstLine);
        el.children.add(_w('ind', attrs));
      }
    }

    // Spacing: explicit when writing a fresh document or the paragraph
    // changed between heading and body text.
    final headingChanged = o != null && o.headingLevel != p.headingLevel;
    if (explicit) {
      _removeAll(el, {'spacing'});
      final attrs = <String, String>{
        'before': _tw(p.spaceBefore),
        'after': _tw(p.spaceAfter),
      };
      if (p.lineExact != null) {
        attrs['line'] = _tw(p.lineExact!);
        attrs['lineRule'] = 'exact';
      } else {
        attrs['line'] = '${(p.lineSpacing * 240).round()}';
        attrs['lineRule'] = 'auto';
      }
      el.children.add(_w('spacing', attrs));
      if (p.keepNext) {
        _removeAll(el, {'keepNext'});
        el.children.add(_w('keepNext'));
      }
      if (p.pageBreakBefore) {
        _removeAll(el, {'pageBreakBefore'});
        el.children.add(_w('pageBreakBefore'));
      }
      if (p.shading != null && _childEl(el, 'shd') == null) {
        el.children.add(
          _w('shd', {
            'val': 'clear',
            'color': 'auto',
            'fill': Ox.colorHex(p.shading!),
          }),
        );
      }
      if (p.rtl && _childEl(el, 'bidi') == null) el.children.add(_w('bidi'));
    } else if (headingChanged) {
      _removeAll(el, {'spacing', 'outlineLvl'});
    }
    if (p.rtl && _childEl(el, 'bidi') == null) el.children.add(_w('bidi'));
    if (!p.rtl && o != null && o.rtl) _removeAll(el, {'bidi'});

    if (sectPr != null) {
      _removeAll(el, {'sectPr'});
      final s = _parseFragment(sectPr);
      if (s != null) el.children.add(s);
    }
    if (el.children.isEmpty) return null;
    _sortChildren(el, _pPrOrder);
    return el.toXmlString();
  }

  String _run(DocText t, DocRunStyle base) {
    final rPr = _rPr(t, base);
    final sb = StringBuffer('<w:r>');
    if (rPr != null) sb.write(rPr);
    final text = t.text;
    var buf = StringBuffer();
    void flush() {
      if (buf.isEmpty) return;
      sb.write('<w:t xml:space="preserve">${xmlEscape(buf.toString())}</w:t>');
      buf = StringBuffer();
    }

    for (final ch in text.runes) {
      if (ch == 0x09) {
        flush();
        sb.write('<w:tab/>');
      } else if (ch == 0x0A || ch == 0x2028) {
        flush();
        sb.write('<w:br/>');
      } else if (ch == 0x2011) {
        flush();
        sb.write('<w:noBreakHyphen/>');
      } else {
        buf.writeCharCode(ch);
      }
    }
    flush();
    sb.write('</w:r>');
    return sb.toString();
  }

  String? _rPr(DocText t, DocRunStyle base) {
    final raw = preserve ? t.raw : null;
    final el = _parseFragment(raw) ?? _w('rPr');
    final s = t.style;
    final o = raw == null ? null : t.origin;
    final fresh = o == null;

    bool changed(Object? a, Object? b) => a != b;

    void toggle(
      String local,
      bool value,
      bool baseValue,
      bool? origin, [
      Set<String> also = const {},
    ]) {
      if (!fresh && origin == value) return; // Untouched: keep raw markup.
      _removeAll(el, {local, ...also});
      if (fresh && value == baseValue) return;
      el.children.add(value ? _w(local) : _w(local, {'val': '0'}));
    }

    toggle('b', s.bold, base.bold, o?.bold, {'bCs'});
    toggle('i', s.italic, base.italic, o?.italic, {'iCs'});
    toggle('strike', s.strike, base.strike, o?.strike, {'dstrike'});
    if (!preserve || raw == null) {
      if (s.allCaps && !base.allCaps) el.children.add(_w('caps'));
      if (s.smallCaps && !base.smallCaps) el.children.add(_w('smallCaps'));
    }

    if (fresh || o.underline != s.underline) {
      _removeAll(el, {'u'});
      if (!(fresh && s.underline == base.underline)) {
        el.children.add(_w('u', {'val': s.underline ? 'single' : 'none'}));
      }
    }
    if (fresh ? changed(s.color, base.color) : changed(s.color, o.color)) {
      _removeAll(el, {'color'});
      el.children.add(
        _w('color', {'val': s.color == null ? 'auto' : Ox.colorHex(s.color!)}),
      );
    }
    if (fresh ? s.highlight != null : changed(s.highlight, o.highlight)) {
      _removeAll(el, {'highlight', 'shd'});
      final hl = s.highlight;
      if (hl != null) {
        final named = _namedHighlights[hl];
        if (named != null) {
          el.children.add(_w('highlight', {'val': named}));
        } else {
          el.children.add(
            _w('shd', {
              'val': 'clear',
              'color': 'auto',
              'fill': Ox.colorHex(hl),
            }),
          );
        }
      }
    }
    if (fresh
        ? changed(s.fontSize, base.fontSize)
        : changed(s.fontSize, o.fontSize)) {
      _removeAll(el, {'sz', 'szCs'});
      if (s.fontSize != null) {
        final hp = '${(s.fontSize! * 2).round()}';
        el.children.add(_w('sz', {'val': hp}));
        el.children.add(_w('szCs', {'val': hp}));
      }
    }
    if (fresh
        ? changed(s.fontFamily, base.fontFamily)
        : changed(s.fontFamily, o.fontFamily)) {
      _removeAll(el, {'rFonts'});
      final f = s.fontFamily;
      if (f != null) {
        el.children.add(
          _w('rFonts', {'ascii': f, 'hAnsi': f, 'cs': f, 'eastAsia': f}),
        );
      }
    }
    if (fresh
        ? s.vertAlign != DocVertAlign.baseline
        : changed(s.vertAlign, o.vertAlign)) {
      _removeAll(el, {'vertAlign'});
      if (s.vertAlign != DocVertAlign.baseline || !fresh) {
        el.children.add(
          _w('vertAlign', {
            'val': switch (s.vertAlign) {
              DocVertAlign.superscript => 'superscript',
              DocVertAlign.subscript => 'subscript',
              DocVertAlign.baseline => 'baseline',
            },
          }),
        );
      }
    }
    if (t.link != null && fresh && _childEl(el, 'rStyle') == null && preserve) {
      el.children.insert(0, _w('rStyle', {'val': 'Hyperlink'}));
    }
    if (el.children.isEmpty) return null;
    _sortChildren(el, _rPrOrder);
    return el.toXmlString();
  }

  // ---------------------------------------------------------------------------
  // Tables

  String _table(DocTable t) {
    if (preserve && t.raw != null) return t.raw!;
    final n = t.columnCount;
    var widths = t.columnWidths.length == n
        ? t.columnWidths
        : List<double>.filled(n, model.page.contentWidth / (n == 0 ? 1 : n));
    final total = widths.fold<double>(0, (a, b) => a + b);
    if (total > model.page.contentWidth * 1.5) {
      final f = model.page.contentWidth / total;
      widths = [for (final w in widths) w * f];
    }
    final border = t.borders
        ? '<w:tblBorders>${['top', 'left', 'bottom', 'right', 'insideH', 'insideV'].map((s) => '<w:$s w:val="single" w:sz="4" w:space="0" w:color="${Ox.colorHex(t.borderColor)}"/>').join()}</w:tblBorders>'
        : '';
    final jc = t.align == DocAlign.center
        ? '<w:jc w:val="center"/>'
        : t.align == DocAlign.right
        ? '<w:jc w:val="right"/>'
        : '';
    final sb = StringBuffer(
      '<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/>$jc$border'
      '<w:tblLayout w:type="fixed"/><w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" '
      'w:firstColumn="1" w:lastColumn="0" w:noHBand="0" w:noVBand="1"/></w:tblPr><w:tblGrid>',
    );
    for (final w in widths) {
      sb.write('<w:gridCol w:w="${_tw(w)}"/>');
    }
    sb.write('</w:tblGrid>');

    // Track vertical merges per grid column.
    final mergeLeft = List<int>.filled(n, 0);
    for (final row in t.rows) {
      sb.write('<w:tr>');
      final trPr = StringBuffer();
      if (row.height != null) {
        trPr.write(
          '<w:trHeight w:val="${_tw(row.height!)}"${row.exactHeight ? ' w:hRule="exact"' : ''}/>',
        );
      }
      if (row.header) trPr.write('<w:tblHeader/>');
      if (trPr.isNotEmpty) sb.write('<w:trPr>$trPr</w:trPr>');
      var col = 0;
      for (final cell in row.cells) {
        final span = cell.colSpan.clamp(1, n == 0 ? 1 : n);
        var cw = 0.0;
        for (var c = col; c < col + span && c < widths.length; c++) {
          cw += widths[c];
        }
        final tcPr = StringBuffer('<w:tcW w:w="${_tw(cw)}" w:type="dxa"/>');
        if (span > 1) tcPr.write('<w:gridSpan w:val="$span"/>');
        if (cell.covered) {
          tcPr.write('<w:vMerge/>');
        } else if (cell.rowSpan > 1) {
          tcPr.write('<w:vMerge w:val="restart"/>');
          if (col < n) mergeLeft[col] = cell.rowSpan - 1;
        }
        if (cell.shading != null) {
          tcPr.write(
            '<w:shd w:val="clear" w:color="auto" w:fill="${Ox.colorHex(cell.shading!)}"/>',
          );
        }
        if (cell.vAlign != DocCellVAlign.top) {
          tcPr.write(
            '<w:vAlign w:val="${cell.vAlign == DocCellVAlign.center ? 'center' : 'bottom'}"/>',
          );
        }
        sb.write('<w:tc><w:tcPr>$tcPr</w:tcPr>');
        final saved = _currentOrderedNum;
        _currentOrderedNum = null;
        final inner = cell.covered ? '' : _body(cell.blocks, null);
        _currentOrderedNum = saved;
        // A cell must end with a paragraph.
        final endsWithP = inner.endsWith('</w:p>');
        sb.write(inner);
        if (!endsWithP) sb.write('<w:p/>');
        sb.write('</w:tc>');
        col += span;
      }
      sb.write('</w:tr>');
    }
    sb.write('</w:tbl>');
    return sb.toString();
  }

  // ---------------------------------------------------------------------------
  // Images

  String _drawing(DocImage img) {
    final data = model.images[img.imageId];
    if (data == null) return '';
    final rel = _imageRel.putIfAbsent(img.imageId, () {
      var ext = data.extension == 'jpeg' ? 'jpeg' : data.extension;
      if (ext == 'bin') ext = sniffImageExtension(data.bytes) ?? 'png';
      String name;
      do {
        name = 'word/media/image_e${_imageNo++}.$ext';
      } while (pkg.has(name));
      pkg.put(name, data.bytes);
      if (preserve) {
        ContentTypes.ensureDefault(
          pkg,
          ext,
          ContentTypes.mimeForExtension(ext) ?? 'application/octet-stream',
        );
      }
      final id = 'rId${_relNo++}';
      _newRels.add(
        _NewRel(
          id,
          '$_relBase/image',
          OfficePackage.relativeTarget(mainPart, name),
        ),
      );
      return id;
    });
    final cx = Units.toEmu(img.width <= 0 ? 144 : img.width);
    final cy = Units.toEmu(img.height <= 0 ? 108 : img.height);
    final id = _docPrId++;
    return '<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">'
        '<wp:extent cx="$cx" cy="$cy"/><wp:docPr id="$id" name="Picture $id"/>'
        '<wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr>'
        '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
        '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:nvPicPr><pic:cNvPr id="$id" name="Picture $id"/><pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="$rel"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
        '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r>';
  }

  // ---------------------------------------------------------------------------
  // Numbering

  String? _numberingPart;
  XmlDocument? _numberingDoc;

  void _scanNumbering() {
    for (final r in pkg.rels(mainPart)) {
      if (r.kind == 'numbering') {
        _numberingPart = OfficePackage.resolve(mainPart, r.target);
      }
    }
    if (_numberingPart != null) _numberingDoc = pkg.xml(_numberingPart!);
    final root = _numberingDoc?.rootElement;
    for (final a in Ox.children(root, 'abstractNum')) {
      final id = int.tryParse(Ox.attr(a, 'abstractNumId') ?? '');
      if (id != null && id >= _nextAbsId) _nextAbsId = id + 1;
    }
    for (final n in Ox.children(root, 'num')) {
      final id = int.tryParse(Ox.attr(n, 'numId') ?? '');
      if (id != null && id >= _nextNumId) _nextNumId = id + 1;
    }
  }

  void _noteExistingNum(DocListInfo list) {
    if (list.ordered) _currentOrderedNum = list.numId;
  }

  String _numIdFor(DocListInfo list) {
    if (!list.ordered) {
      if (_bulletNumId == null) {
        _bulletAbsId ??= '${_nextAbsId++}';
        _bulletNumId = '${_nextNumId++}';
        _newNums.add((_bulletNumId!, _bulletAbsId!, false));
      }
      return _bulletNumId!;
    }
    if (_currentOrderedNum != null) return _currentOrderedNum!;
    _orderedAbsId ??= '${_nextAbsId++}';
    final id = '${_nextNumId++}';
    _newNums.add((id, _orderedAbsId!, true));
    _currentOrderedNum = id;
    return id;
  }

  String _abstractXml(String id, bool ordered) {
    final sb = StringBuffer(
      '<w:abstractNum w:abstractNumId="$id"><w:multiLevelType w:val="hybridMultilevel"/>',
    );
    for (var l = 0; l < 9; l++) {
      final left = 720 * (l + 1);
      if (ordered) {
        final fmt = const ['decimal', 'lowerLetter', 'lowerRoman'][l % 3];
        sb.write(
          '<w:lvl w:ilvl="$l"><w:start w:val="1"/><w:numFmt w:val="$fmt"/>'
          '<w:lvlText w:val="%${l + 1}."/><w:lvlJc w:val="left"/>'
          '<w:pPr><w:ind w:left="$left" w:hanging="360"/></w:pPr></w:lvl>',
        );
      } else {
        final ch = const ['•', '◦', '▪'][l % 3];
        sb.write(
          '<w:lvl w:ilvl="$l"><w:start w:val="1"/><w:numFmt w:val="bullet"/>'
          '<w:lvlText w:val="$ch"/><w:lvlJc w:val="left"/>'
          '<w:pPr><w:ind w:left="$left" w:hanging="360"/></w:pPr></w:lvl>',
        );
      }
    }
    sb.write('</w:abstractNum>');
    return sb.toString();
  }

  String _numXml(String numId, String absId, bool restart) {
    final override = restart
        ? '<w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/></w:lvlOverride>'
        : '';
    return '<w:num w:numId="$numId"><w:abstractNumId w:val="$absId"/>$override</w:num>';
  }

  void _writeNumbering() {
    if (_newNums.isEmpty) return;
    final abstracts = StringBuffer();
    if (_bulletAbsId != null) {
      abstracts.write(_abstractXml(_bulletAbsId!, false));
    }
    if (_orderedAbsId != null) {
      abstracts.write(_abstractXml(_orderedAbsId!, true));
    }
    final nums = StringBuffer();
    for (final n in _newNums) {
      nums.write(_numXml(n.$1, n.$2, n.$3));
    }
    if (_numberingPart != null && _numberingDoc != null) {
      final text = pkg.text(_numberingPart!)!;
      // Insert abstracts after the last abstractNum (or before the first
      // num), nums before </w:numbering> (before numIdMacAtCleanup).
      var t = text;
      final lastAbs = t.lastIndexOf(
        RegExp(r'</([A-Za-z_][\w.\-]*:)?abstractNum>'),
      );
      int absInsert;
      if (lastAbs >= 0) {
        absInsert = t.indexOf('>', lastAbs) + 1;
      } else {
        final firstNum = RegExp(
          r'<([A-Za-z_][\w.\-]*:)?num[\s>]',
        ).firstMatch(t);
        absInsert =
            firstNum?.start ??
            t.lastIndexOf(RegExp(r'</([A-Za-z_][\w.\-]*:)?numbering>'));
      }
      t = t.replaceRange(absInsert, absInsert, abstracts.toString());
      final cleanup = RegExp(
        r'<([A-Za-z_][\w.\-]*:)?numIdMacAtCleanup',
      ).firstMatch(t);
      final close =
          cleanup?.start ??
          t.lastIndexOf(RegExp(r'</([A-Za-z_][\w.\-]*:)?numbering>'));
      t = t.replaceRange(close, close, nums.toString());
      pkg.putText(_numberingPart!, _ensureW(t, 'numbering'));
    } else {
      _numberingPart = 'word/numbering.xml';
      pkg.putText(
        _numberingPart!,
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:numbering xmlns:w="$_nsW">$abstracts$nums</w:numbering>',
      );
      ContentTypes.ensureOverride(
        pkg,
        _numberingPart!,
        'application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml',
      );
      final id = 'rId${_relNo++}';
      _newRels.add(
        _NewRel(
          id,
          '$_relBase/numbering',
          OfficePackage.relativeTarget(mainPart, _numberingPart!),
        ),
      );
    }
  }

  String _ensureW(String text, String rootLocal) {
    final root = RegExp(
      '<([A-Za-z_][\\w.\\-]*:)?$rootLocal\\b[^>]*>',
    ).firstMatch(text);
    if (root == null) return text;
    final tag = root.group(0)!;
    if (tag.contains('xmlns:w=')) return text;
    final closing = tag.endsWith('/>') ? 2 : 1;
    final fixed =
        '${tag.substring(0, tag.length - closing)} xmlns:w="$_nsW"${tag.substring(tag.length - closing)}';
    return text.replaceRange(root.start, root.end, fixed);
  }

  String _freshNumbering() {
    final sb = StringBuffer(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:numbering xmlns:w="$_nsW">',
    );
    if (_bulletAbsId != null) sb.write(_abstractXml(_bulletAbsId!, false));
    if (_orderedAbsId != null) sb.write(_abstractXml(_orderedAbsId!, true));
    for (final n in _newNums) {
      sb.write(_numXml(n.$1, n.$2, n.$3));
    }
    sb.write('</w:numbering>');
    return sb.toString();
  }

  void _writeRels() {
    if (_newRels.isEmpty) return;
    final path = OfficePackage.relsPathFor(mainPart);
    var text =
        pkg.text(path) ??
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>';
    final add = StringBuffer();
    for (final r in _newRels) {
      add.write(
        '<Relationship Id="${r.id}" Type="${xmlEscape(r.type)}" '
        'Target="${xmlEscape(r.target)}"${r.external ? ' TargetMode="External"' : ''}/>',
      );
    }
    final close = text.lastIndexOf('</Relationships>');
    if (close < 0) {
      text = text.replaceFirst(
        RegExp(r'<Relationships([^>]*)/>'),
        '<Relationships\$1>$add</Relationships>',
      );
    } else {
      text = text.replaceRange(close, close, add.toString());
    }
    pkg.putText(path, text);
  }

  // ---------------------------------------------------------------------------
  // Fresh styles

  String _rPrFor(DocRunStyle s, DocRunStyle base) {
    final sb = StringBuffer();
    if (s.fontFamily != null && s.fontFamily != base.fontFamily) {
      final f = xmlEscape(s.fontFamily!);
      sb.write('<w:rFonts w:ascii="$f" w:hAnsi="$f" w:cs="$f"/>');
    }
    if (s.bold) sb.write('<w:b/>');
    if (s.italic) sb.write('<w:i/>');
    if (s.color != null) {
      sb.write('<w:color w:val="${Ox.colorHex(s.color!)}"/>');
    }
    if (s.fontSize != null) {
      final hp = (s.fontSize! * 2).round();
      sb.write('<w:sz w:val="$hp"/><w:szCs w:val="$hp"/>');
    }
    if (s.underline) sb.write('<w:u w:val="single"/>');
    return sb.toString();
  }

  String _freshStyles() {
    final base = model.baseStyle;
    final font = xmlEscape(base.fontFamily ?? 'Calibri');
    final hp = ((base.fontSize ?? 11) * 2).round();
    final sb = StringBuffer(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:styles xmlns:w="$_nsW">'
      '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="$font" w:hAnsi="$font" w:cs="$font" w:eastAsia="$font"/>'
      '<w:sz w:val="$hp"/><w:szCs w:val="$hp"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault>'
      '<w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
      '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>',
    );
    for (var l = 1; l <= 6; l++) {
      final h = model.headingStyles[l] ?? base;
      final before = _tw(model.headingSpacing[l] ?? 12);
      sb.write(
        '<w:style w:type="paragraph" w:styleId="Heading$l"><w:name w:val="heading $l"/>'
        '<w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>'
        '<w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="$before" w:after="80"/><w:outlineLvl w:val="${l - 1}"/></w:pPr>'
        '<w:rPr>${_rPrFor(h, base)}</w:rPr></w:style>',
      );
    }
    sb.write(
      '<w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont">'
      '<w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/><w:unhideWhenUsed/></w:style>'
      '<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/>'
      '<w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/>'
      '<w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/>'
      '<w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>'
      '<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/>'
      '<w:basedOn w:val="DefaultParagraphFont"/><w:uiPriority w:val="99"/><w:unhideWhenUsed/>'
      '<w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>'
      '</w:styles>',
    );
    return sb.toString();
  }
}
