// Shared sentence-aware EPUB pagination, ported from the Android reader.
// WebKit supplies Japanese word segmentation and all glyph/column measurement. CSS has no
// sentence-boundary primitive: markers preserve publisher markup while choosing column breaks.
// Oversized sentences retain ordinary continuation and all enhancement failures fall back to it.
// SPDX-License-Identifier: GPL-3.0-or-later

(function () {
  'use strict';
  // One layout per document. A second copy would wrap the words again and place a second set
  // of sentence breaks over the first set.
  if (window.hoshiTextLayout) return;
  // Reuse one live Range: thousands of detached ranges make every later DOM mutation quadratic.
  // Park it in a detached node while editing the page, so no mutation has to update its
  // boundary offsets (each update walks the children of a possibly very long paragraph).
  var workingRange = document.createRange();
  var parking = document.createTextNode('');
  function park() { workingRange.setStart(parking, 0); workingRange.collapse(true); }
  park();
  var segmenters = {};
  var SKIP = 'rt,rp,script,style,noscript,svg,math,textarea,pre,code';
  var BLOCK = 'p,div,li,dd,dt,blockquote,figcaption,h1,h2,h3,h4,h5,h6,td,th,section,article';
  var VISIBLE_EMPTY = 'img,svg,video,audio,canvas,iframe,object,embed,br,hr,input,.hoshi-tl';
  var MEDIA = 'img,svg,video,canvas,iframe,object,embed';
  var MARKER_BREAK = 'hoshi-sentence-page-break', BLOCK_BREAK = 'hoshi-sentence-block-break',
    BREAK_HOST = 'hoshi-sentence-break-host';
  // Each pass costs one chapter layout; the model normally settles within a few. The exact
  // fallback costs a layout per page, so it gets a hard budget and leaves the rest unbroken.
  var MAX_PASSES = 12, FALLBACK_LAYOUTS = 24, FALLBACK_MILLIS = 200;
  function runs() {
    var out = [], current = null, blocks = new WeakMap();
    function blockFor(element) {
      if (!element || element === document.body) return document.body;
      if (blocks.has(element)) return blocks.get(element);
      var display = getComputedStyle(element).display;
      var block = element.matches(BLOCK) || /^(block|flow-root|list-item|flex|grid|table|table-.+)$/.test(display)
        ? element : blockFor(element.parentElement);
      blocks.set(element, block);
      return block;
    }
    // A hard break or a replaced element separates authored lines, even when both sides
    // have the same paragraph parent. Never turn those lines into one inline word box.
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        if (node.nodeType === Node.ELEMENT_NODE) {
          if (node.matches('rt,rp')) return NodeFilter.FILTER_REJECT;
          if (node.matches(SKIP) || getComputedStyle(node).display === 'none') {
            current = null;
            return NodeFilter.FILTER_REJECT;
          }
          if (node.matches('br,hr,img,video,audio,canvas,iframe,object,embed')) {
            current = null;
            return NodeFilter.FILTER_REJECT;
          }
          if (blockFor(node) === node) current = null;
          return NodeFilter.FILTER_SKIP;
        }
        return node.nodeValue ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
      }
    });
    var node;
    while ((node = walker.nextNode())) {
      var block = blockFor(node.parentElement);
      if (!current || current.block !== block) {
        current = { block: block, text: '', nodes: [] }; out.push(current);
      }
      current.nodes.push({ node: node, start: current.text.length });
      current.text += node.nodeValue;
    }
    return out;
  }
  function point(run, offset, endBoundary) {
    var low = 0, high = run.nodes.length;
    while (low < high) {
      var middle = (low + high) >>> 1;
      if (run.nodes[middle].start < offset || (!endBoundary && run.nodes[middle].start === offset)) low = middle + 1;
      else high = middle;
    }
    var item = run.nodes[Math.max(0, low - 1)];
    return { node: item.node, offset: Math.max(0, Math.min(offset - item.start, item.node.length)) };
  }
  function isEmptyNode(node) {
    return node.nodeType === Node.COMMENT_NODE || (node.nodeType === Node.TEXT_NODE && !node.nodeValue.length);
  }
  function onlyEmptySiblings(node, forward) {
    for (var sibling = forward ? node.nextSibling : node.previousSibling; sibling;
      sibling = forward ? sibling.nextSibling : sibling.previousSibling) {
      if (!isEmptyNode(sibling)) return false;
    }
    return true;
  }
  // First and last nodes of a word, splitting text at its edges and keeping a ruby whole.
  function wordNodes(run, start, end) {
    var a = point(run, start), b = point(run, end, true), first, last;
    var firstRuby = a.node.parentElement.closest('ruby');
    var lastRuby = b.node.parentElement.closest('ruby');
    // Split the end first: splitting the start would move the end offset into a new node.
    if (lastRuby && b.offset === b.node.length) last = lastRuby;
    else {
      if (b.offset < b.node.length) b.node.splitText(b.offset);
      last = b.node;
    }
    if (firstRuby && a.offset === 0 && firstRuby.textContent) first = firstRuby;
    else if (a.offset > 0) {
      first = a.node.splitText(a.offset);
      if (last === a.node) last = first;
    } else first = a.node;
    if (first !== last && first.contains(last)) last = first;
    else if (first !== last && last.contains(first)) first = last;
    return { first: first, last: last };
  }
  // Move whole sibling nodes into the holder. Only a word that ends part-way through a
  // publisher element needs Range's partial-element cloning.
  function wrapNodes(first, last, holder) {
    var common = first === last ? first.parentNode : last.parentNode;
    while (!common.contains(first)) common = common.parentNode;
    while (first.parentNode !== common && onlyEmptySiblings(first, false)) first = first.parentNode;
    while (last.parentNode !== common && onlyEmptySiblings(last, true)) last = last.parentNode;
    if (first.parentNode === common && last.parentNode === common) {
      common.insertBefore(holder, first);
      for (var node = first; node;) {
        var next = node.nextSibling;
        holder.appendChild(node);
        if (node === last) break;
        node = next;
      }
      return;
    }
    var range = workingRange;
    if (first.nodeType === Node.TEXT_NODE) range.setStart(first, 0); else range.setStartBefore(first);
    if (last.nodeType === Node.TEXT_NODE) range.setEnd(last, last.length); else range.setEndAfter(last);
    holder.appendChild(range.extractContents());
    holder.querySelectorAll('[id]').forEach(function (copy) {
      var original = document.getElementById(copy.id);
      if (original && original !== copy) copy.removeAttribute('id');
    });
    range.insertNode(holder);
    park();
  }
  function words(text) {
    if (window.Intl && Intl.Segmenter) {
      var segmenter = segmenters.word || (segmenters.word = new Intl.Segmenter('ja', { granularity: 'word' }));
      return Array.from(segmenter.segment(text));
    }
    var found = [], regex = /[\p{Script=Han}々〻]+/gu, match;
    while ((match = regex.exec(text))) found.push({ index: match.index, segment: match[0], isWordLike: true });
    return found;
  }
  // Ruby bases of a run as [start, end) offsets into its text.
  function rubySpans(run) {
    var spans = new Map();
    run.nodes.forEach(function (item) {
      var ruby = item.node.parentElement.closest('ruby');
      if (!ruby) return;
      var previous = spans.get(ruby);
      spans.set(ruby, { start: previous ? Math.min(previous.start, item.start) : item.start, end: item.start + item.node.length });
    });
    return spans;
  }
  // Sentences as sentence mode splits them (EpubSentenceSegmenter): 。！？!? end a sentence and
  // keep the closing brackets and ellipses after them, so an opening bracket starts the next
  // sentence. A terminator inside a ruby base waits for the base to end.
  var TERMINATORS = '。！？!?', TRAILING = '。、！？…‥」』）)】〉》〕｝}］]';
  function sentenceParts(run) {
    var text = run.text, parts = [], start = 0, inside = [];
    rubySpans(run).forEach(function (span) { inside.push(span); });
    function splitsRuby(offset) {
      return inside.some(function (span) { return span.start < offset && offset < span.end; });
    }
    for (var index = 0; index < text.length; index++) {
      if (TERMINATORS.indexOf(text[index]) < 0) continue;
      var end = index + 1;
      while (end < text.length && TRAILING.indexOf(text[end]) >= 0) end++;
      index = end - 1;
      if (splitsRuby(end)) continue;
      parts.push({ index: start, segment: text.slice(start, end) });
      start = end;
    }
    if (start < text.length) parts.push({ index: start, segment: text.slice(start) });
    return parts;
  }
  function wrapWords() {
    runs().forEach(function (run) {
      var found = words(run.text).filter(function (word) {
        return word.isWordLike && /[\p{Script=Han}々〻]/u.test(word.segment);
      });
      var spans = rubySpans(run);
      found = found.map(function (word) {
        var start = word.index, end = start + word.segment.length;
        spans.forEach(function (ruby) {
          if (ruby.start < end && ruby.end > start) { start = Math.min(start, ruby.start); end = Math.max(end, ruby.end); }
        });
        return { index: start, segment: run.text.slice(start, end) };
      }).reduce(function (merged, word) {
        var previous = merged[merged.length - 1];
        if (previous && word.index < previous.index + previous.segment.length) {
          previous.segment = run.text.slice(previous.index, Math.max(previous.index + previous.segment.length, word.index + word.segment.length));
        } else merged.push(word);
        return merged;
      }, []);
      // Descending words retain offsets in the untouched prefix of every original text node.
      found.reverse().forEach(function (word) {
        var nodes = wordNodes(run, word.index, word.index + word.segment.length);
        var holder = document.createElement('span'); holder.className = 'hoshi-word';
        wrapNodes(nodes.first, nodes.last, holder);
      });
    });
    document.querySelectorAll('ruby').forEach(function (ruby) {
      if (ruby.closest('.hoshi-word')) return;
      var holder = document.createElement('span'); holder.className = 'hoshi-word';
      ruby.before(holder); holder.appendChild(ruby);
    });
    var bodyStyle = getComputedStyle(document.body);
    var vertical = bodyStyle.writingMode.indexOf('vertical') === 0;
    var available = vertical
      ? window.innerHeight - parseFloat(bodyStyle.paddingTop) - parseFloat(bodyStyle.paddingBottom)
      : window.innerWidth - parseFloat(bodyStyle.paddingLeft) - parseFloat(bodyStyle.paddingRight);
    document.querySelectorAll('.hoshi-word').forEach(function (word) {
      var rect = word.getBoundingClientRect(), inlineSize = vertical ? rect.height : rect.width;
      if (inlineSize > available && available > 0) {
        // A whole word or unusually long reading must remain accessible in a narrow pane.
        word.style.fontSize = (parseFloat(getComputedStyle(word).fontSize) * available / inlineSize) + 'px';
      }
    });
  }
  function emptySibling(node) {
    return isEmptyNode(node) ||
      (node.nodeType === Node.ELEMENT_NODE && node.matches('rt,rp,.hoshi-sentence-start,.hoshi-sentence-end'));
  }
  function blankBeforeBlockText(node) {
    return emptySibling(node) || (node.nodeType === Node.ELEMENT_NODE && !node.textContent &&
      !node.matches(VISIBLE_EMPTY) && !node.querySelector(VISIBLE_EMPTY));
  }
  // Inserts a sentence marker; returns true when a start marker opens its block's content.
  function insertMarker(location, marker, after, block) {
    // Keep forced column breaks outside a complete inline publisher element. Older WebView
    // versions can ignore a block break nested in an inline span. Replaced elements and hard
    // breaks still count as siblings even though their textContent is empty.
    var boundary = location.node, edge = location.offset === (after ? boundary.length : 0);
    while (edge && boundary.parentElement && boundary.parentElement !== document.body && boundary.parentElement !== block) {
      var parent = boundary.parentElement;
      var sibling = after ? boundary.nextSibling : boundary.previousSibling;
      while (sibling && emptySibling(sibling)) sibling = after ? sibling.nextSibling : sibling.previousSibling;
      if (sibling) break;
      boundary = parent;
    }
    var opensBlock = false;
    if (!after && edge && block !== document.body && boundary.parentElement === block) {
      var previous = boundary.previousSibling;
      while (previous && blankBeforeBlockText(previous)) previous = previous.previousSibling;
      opensBlock = !previous;
    }
    if (boundary !== location.node) {
      if (after) boundary.after(marker); else boundary.before(marker);
    } else if (location.offset === 0) {
      location.node.before(marker);
    } else if (location.offset === location.node.length) {
      location.node.after(marker);
    } else {
      location.node.splitText(location.offset).before(marker);
    }
    return opensBlock;
  }
  function sentenceAnchors() {
    var sentences = [];
    runs().forEach(function (run, runIndex) {
      var parts = sentenceParts(run), runSentences = [];
      // A table lays out its own rows: WebView 133 moves a break inside a cell to the row and
      // leaves near-empty pages around it, so table text only continues across pages.
      var inTable = run.block !== document.body && !!run.block.closest('table');
      var blockBreaks = run.block !== document.body &&
        /^(block|flow-root|list-item|flex|grid|table)$/.test(getComputedStyle(run.block).display);
      for (var i = parts.length - 1; i >= 0; i--) {
        var part = parts[i];
        if (!part.segment.trim()) continue;
        var a = point(run, part.index), b = point(run, part.index + part.segment.length, true);
        var end = document.createElement('span'), start = document.createElement('span');
        end.className = 'hoshi-sentence-end'; start.className = 'hoshi-sentence-start';
        end.setAttribute('aria-hidden', 'true'); start.setAttribute('aria-hidden', 'true');
        insertMarker(b, end, true, run.block);
        var opensBlock = insertMarker(a, start, false, run.block);
        // A sentence that opens its block breaks before the block itself: a block marker
        // inside the paragraph would make the following text a continuation line and drop
        // the paragraph's first-line indent.
        runSentences.push({ start: start, end: end, text: part.segment, block: run.block, run: runIndex, opensBlock: opensBlock,
          inTable: inTable, breakTarget: opensBlock && blockBreaks ? run.block : start,
          breakClass: opensBlock && blockBreaks ? BLOCK_BREAK : MARKER_BREAK });
      }
      // Runs already follow document order, so reverse each run's insertion order directly.
      runSentences.reverse().forEach(function (sentence) { sentences.push(sentence); });
    });
    return sentences;
  }
  function hasBreak(sentence) { return sentence.breakTarget.classList.contains(sentence.breakClass); }
  // An inline element that only passes styles on to its text, so its text looks the same
  // without the element's own box. Links keep theirs.
  function drawsNothing(element) {
    if (element.classList.contains(BREAK_HOST)) return true;
    if (element.matches('a,.hoshi-word,ruby,rb,rt,rp,bdi,bdo')) return false;
    var style = getComputedStyle(element);
    if (style.display !== 'inline' || style.position !== 'static' || style.verticalAlign !== 'baseline' ||
        style.textDecorationLine !== 'none' || style.backgroundImage !== 'none' || style.boxShadow !== 'none' ||
        style.outlineStyle !== 'none' || style.opacity !== '1' || style.unicodeBidi !== 'normal' ||
        !/^(transparent|rgba\(0, ?0, ?0, ?0\))$/.test(style.backgroundColor)) return false;
    return ['Top', 'Right', 'Bottom', 'Left'].every(function (side) {
      return !parseFloat(style['margin' + side]) && !parseFloat(style['padding' + side]) && !parseFloat(style['border' + side + 'Width']);
    });
  }
  // Android WebView 133 applies a block break nested in an inline element before the whole
  // paragraph. While such a break is in place, the inline elements around it give up their
  // boxes so that it stands directly in the paragraph; only when none of them draws anything.
  function breakHosts(marker, block) {
    var hosts = [];
    for (var parent = marker.parentElement; parent && parent !== block && parent !== document.body; parent = parent.parentElement) {
      if (!drawsNothing(parent)) return [];
      hosts.push(parent);
    }
    return hosts;
  }
  function setBreak(sentence, on) {
    if (on) sentence.breakTarget.classList.add(sentence.breakClass);
    else sentence.breakTarget.classList.remove(sentence.breakClass);
    if (sentence.breakClass !== MARKER_BREAK) return;
    if (on && !sentence.hosts) sentence.hosts = breakHosts(sentence.start, sentence.block);
    (sentence.hosts || []).forEach(function (host) {
      if (on) host.classList.add(BREAK_HOST);
      else if (!host.querySelector('.' + MARKER_BREAK)) host.classList.remove(BREAK_HOST);
    });
  }
  function isOversized(sentence) { return sentence.inTable || sentence.start.dataset.oversized === 'true'; }
  // The column box along the block axis: lines advance down (horizontal) or leftwards (vertical).
  function columnGeometry(context) {
    var style = getComputedStyle(document.body), body = document.body;
    if (context.vertical) {
      var right = body.clientWidth - parseFloat(style.paddingRight);
      return { origin: right, capacity: right - parseFloat(style.paddingLeft), inlineOrigin: parseFloat(style.paddingTop),
        inlineSize: body.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom) };
    }
    var top = parseFloat(style.paddingTop);
    return { origin: top, capacity: body.clientHeight - parseFloat(style.paddingBottom) - top, inlineOrigin: parseFloat(style.paddingLeft),
      inlineSize: body.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight) };
  }
  // The page whose column holds a span along the page axis. A line fragment never spans two
  // columns, but glyphs can stand outside the column box: a negative text indent hangs the
  // first glyphs into the gap before a column, or even over the previous column's end.
  function columnOf(a, b, context, geometry) {
    var size = context.pageSize, origin = geometry.inlineOrigin, inline = geometry.inlineSize;
    var middle = (a + b) / 2, page = Math.floor((middle - origin) / size);
    if (middle - origin - page * size <= inline) return page;
    // Between two columns: the end of a line that overflows, or the hanging start of the next.
    var start = page * size + origin, next = start + size;
    var current = Math.min(b, start + inline) - Math.max(a, start);
    var following = Math.min(b, next + inline) - Math.max(a, next);
    return current > 0 && current >= following ? page : page + 1;
  }
  function boxFor(rect, context, geometry, scroll) {
    var a = (context.vertical ? rect.top : rect.left) + scroll;
    var b = (context.vertical ? rect.bottom : rect.right) + scroll;
    return {
      a: a, b: b,
      start: context.vertical ? geometry.origin - rect.right : rect.top - geometry.origin,
      end: context.vertical ? geometry.origin - rect.left : rect.bottom - geometry.origin
    };
  }
  function placeBox(box, page, context, geometry) {
    box.page = page;
    box.inlineStart = box.a - page * context.pageSize - geometry.inlineOrigin;
    box.inlineEnd = box.b - page * context.pageSize - geometry.inlineOrigin;
  }
  // Pages of a sentence's fragments, decided per line: fragments that share a line and touch
  // along it belong to the column holding most of that line, wherever single glyphs hang.
  function measure(sentence, context, geometry, scroll, withBoxes) {
    var range = workingRange; range.setStart(sentence.start, 0); range.setEnd(sentence.end, 0);
    var rects = range.getClientRects(), first = Infinity, last = -Infinity, boxes = [], line = [];
    function settle() {
      if (!line.length) return;
      var a = Infinity, b = -Infinity;
      line.forEach(function (box) { a = Math.min(a, box.a); b = Math.max(b, box.b); });
      var page = columnOf(a, b, context, geometry);
      line.forEach(function (box) { placeBox(box, page, context, geometry); });
      first = Math.min(first, page); last = Math.max(last, page);
      line = [];
    }
    for (var i = 0; i < rects.length; i++) {
      var rect = rects[i];
      if (rect.width <= 0 || rect.height <= 0) continue;
      var box = boxFor(rect, context, geometry, scroll), previous = line[line.length - 1];
      var reach = Math.max(box.end - box.start, previous ? previous.end - previous.start : 0);
      if (previous && !(Math.min(box.end, previous.end) > Math.max(box.start, previous.start) &&
          box.a <= previous.b + reach && box.b >= previous.a - reach)) settle();
      line.push(box); boxes.push(box);
    }
    settle();
    return { first: first, last: last, boxes: withBoxes ? boxes : null };
  }
  function blockMargin(element, end, vertical) {
    var style = getComputedStyle(element);
    return parseFloat(vertical ? (end ? style.marginLeft : style.marginRight) : (end ? style.marginBottom : style.marginTop)) || 0;
  }
  // Border and padding a block keeps before its first line, or after its last one.
  function blockInset(element, end, vertical) {
    var style = getComputedStyle(element);
    var side = vertical ? (end ? 'Left' : 'Right') : (end ? 'Bottom' : 'Top');
    return (parseFloat(style['padding' + side]) || 0) + (parseFloat(style['border' + side + 'Width']) || 0);
  }
  // Reads the unbroken chapter once and lays its lines end to end along the block axis: each
  // page's unused tail is removed and a paragraph margin truncated at a page boundary is
  // restored. Lines are numbered in reading order; ruby annotations are smaller boxes on the
  // same line. Positions in this flow do not depend on breaks applied later.
  function naturalFlow(sentences, context, geometry, media) {
    var scroll = context.vertical ? context.scrollEl.scrollTop : context.scrollEl.scrollLeft;
    var used = {}, tops = {}, opener = {}, lastPage = -1;
    function note(box, index) {
      used[box.page] = Math.max(used[box.page] === undefined ? -Infinity : used[box.page], box.end);
      if (tops[box.page] === undefined || box.start < tops[box.page]) { tops[box.page] = box.start; opener[box.page] = index; }
      lastPage = Math.max(lastPage, box.page);
    }
    var measured = sentences.map(function (sentence, index) {
      var measurement = measure(sentence, context, geometry, scroll, true);
      measurement.boxes.forEach(function (box) { note(box, index); });
      return measurement;
    });
    var mediaBoxes = [];
    media.forEach(function (element) {
      var rect = element.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) return;
      var box = boxFor(rect, context, geometry, scroll);
      placeBox(box, columnOf(box.a, box.b, context, geometry), context, geometry);
      note(box, -1); mediaBoxes.push(box);
    });
    var sizes = [], textEnd = -Infinity;
    for (var sample = 0; sample < measured.length && sizes.length < 512; sample++) {
      measured[sample].boxes.forEach(function (box) { sizes.push(box.end - box.start); });
    }
    sizes.sort(function (x, y) { return x - y; });
    var textSize = sizes.length ? sizes[sizes.length >> 1] : 0;
    var textBoxes = [], annotations = [];
    measured.forEach(function (measurement) {
      measurement.boxes.forEach(function (box) {
        (box.end - box.start < textSize * 0.75 ? annotations : textBoxes).push(box);
      });
    });
    textBoxes.sort(function (x, y) { return x.page - y.page || x.end - y.end; });
    var ordinal = -1, previousBox = null, lineEnds = [], lineStarts = [], pageLines = {}, advances = [];
    textBoxes.forEach(function (box) {
      if (!previousBox || box.page !== previousBox.page || box.end - previousBox.end > 3) {
        if (previousBox && box.page === previousBox.page) advances.push(box.end - previousBox.end);
        lineEnds[++ordinal] = 0;
        lineStarts[ordinal] = Infinity;
        (pageLines[box.page] = pageLines[box.page] || []).push(ordinal);
      }
      box.ordinal = ordinal; previousBox = box;
      lineEnds[ordinal] = Math.max(lineEnds[ordinal], box.inlineEnd);
      lineStarts[ordinal] = Math.min(lineStarts[ordinal], box.start);
    });
    // Lines carrying ruby right before their text. WebView 133 never moves such a line that
    // opens a paragraph to the next page, so it can overhang the column: it does not show
    // where text fits.
    var annotated = {};
    annotations.forEach(function (box) {
      (pageLines[box.page] || []).forEach(function (line) {
        if (Math.abs(lineStarts[line] - box.end) <= 2) annotated[line] = true;
      });
    });
    textBoxes.forEach(function (box) { if (!annotated[box.ordinal]) textEnd = Math.max(textEnd, box.end); });
    advances.sort(function (x, y) { return x - y; });
    // Half the leading sits above and below each plain line; the closest lines show it. A page
    // ends where text still fits: at least above the leading under its last line, and as low
    // as any page already holds plain text.
    var plainAdvance = advances.length ? advances[Math.floor(advances.length * 0.1)] : textSize;
    var lead = Math.min(Math.max(0, plainAdvance - textSize) / 2, geometry.capacity / 4);
    var bottom = Math.min(geometry.capacity, Math.max(isFinite(textEnd) ? textEnd : 0, geometry.capacity - lead));
    var flow = [0];
    for (var page = 0; page <= lastPage; page++) {
      var opening = sentences[opener[page + 1]];
      flow[page + 1] = flow[page] + (used[page] === undefined ? 0 : used[page] + lead) + (opening ? opening.gapBefore : 0);
    }
    sentences.forEach(function (sentence, index) {
      var first = null, last = null, top = null;
      var lines = measured[index].boxes.map(function (box) {
        if (!top || box.page < top.page || (box.page === top.page && box.start < top.start - 0.5)) top = box;
        if (box.ordinal !== undefined) {
          if (!first || box.ordinal < first.ordinal || (box.ordinal === first.ordinal && box.inlineStart < first.inlineStart)) first = box;
          if (!last || box.ordinal > last.ordinal || (box.ordinal === last.ordinal && box.inlineEnd > last.inlineEnd)) last = box;
        }
        return [flow[box.page] + box.start, flow[box.page] + box.end];
      });
      lines.sort(function (x, y) { return x[0] - y[0]; });
      sentence.lines = lines;
      sentence.flowStart = lines.length ? lines[0][0] : NaN;
      // How far below a page's top this sentence's first box sits when it opens the page.
      sentence.inset = (top && top.end - top.start < textSize * 0.75 ? 0 : lead) + sentence.blockInset;
      sentence.flowEnd = lines.reduce(function (value, line) { return Math.max(value, line[1]); }, -Infinity);
      // Where the sentence begins and ends along numbered lines, to estimate rewrapping.
      sentence.firstLine = first ? first.ordinal : null;
      sentence.lastLine = last ? last.ordinal : null;
      sentence.inlineStart = first ? first.inlineStart : 0;
      sentence.inlineEnd = last ? last.inlineEnd : 0;
    });
    // Lines hold whole words, so they usually end short of the column; full lines show how much.
    lineEnds.sort(function (x, y) { return x - y; });
    return {
      lead: lead,
      bottom: bottom,
      textSize: textSize,
      // The usual distance between lines, ruby included.
      line: advances.length ? advances[advances.length >> 1] : textSize + 2 * lead,
      lineFill: lineEnds.length ? Math.min(geometry.inlineSize, lineEnds[Math.floor(lineEnds.length * 0.75)]) : 0,
      media: mediaBoxes.map(function (box) { return [flow[box.page] + box.start, flow[box.page] + box.end]; })
        .sort(function (x, y) { return x[0] - y[0]; })
    };
  }
  // Pages holding a replaced element such as an illustration, which is content of its own.
  function mediaPages(media, context, geometry) {
    var scroll = context.vertical ? context.scrollEl.scrollTop : context.scrollEl.scrollLeft, pages = {};
    media.forEach(function (element) {
      var rect = element.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) return;
      var box = boxFor(rect, context, geometry, scroll);
      pages[columnOf(box.a, box.b, context, geometry)] = true;
    });
    return pages;
  }
  // One pass reads the layout from where the previous pass first changed a break, since
  // nothing before that point moved. While the breaks in place are kept, decisions follow the
  // real layout exactly. After a change, the natural flow predicts the content it moves until
  // the next break that stays: a forced break makes everything after it independent of the
  // rest. An existing break is only dropped when its sentence fits with a line to spare, so
  // near calls cannot flip the same break back and forth between passes. A break the real
  // layout required stops the estimate, which keeps a correction from rippling through the
  // rest of the chapter.
  function planPass(sentences, context, geometry, natural, media, resume) {
    var scroll = context.vertical ? context.scrollEl.scrollTop : context.scrollEl.scrollLeft;
    var lead = natural.lead, bottom = natural.bottom, tolerance = 0.5;
    var synced = true, page = resume.page, pageTop = resume.pageTop, nextMedia = resume.nextMedia;
    var rewrap = resume.rewrap && { run: resume.rewrap.run, line: resume.rewrap.line, offset: resume.rewrap.offset, tail: resume.rewrap.tail };
    var changes = 0, next = null, before = null, actual = [], droppedStale = false;
    // Read every position before changing a break: a read after a change lays out the chapter.
    // The line before the first sentence read can matter as well.
    for (var read = Math.max(0, resume.index - 16); read < sentences.length; read++) {
      actual[read] = sentences[read].lines.length ? measure(sentences[read], context, geometry, scroll, true) : null;
    }
    var illustrated = mediaPages(media, context, geometry);
    // A page with no sentence or illustration before this one would be left blank by a break:
    // an empty separator paragraph is all it holds. Such a sentence continues across instead.
    function leavesBlankPage(blankPage, previousLast) {
      return previousLast < blankPage && !illustrated[blankPage];
    }
    // Where a sentence opening a page after its forced break would sit on the page before, from
    // the real layout. Assumes it starts a new line there, so it never claims too much room.
    function placeWithoutBreak(sentence, measurement, previous) {
      if (!previous || !previous.boxes || !measurement.boxes || previous.last !== measurement.first - 1) return null;
      var previousEnd = -Infinity, top = Infinity, bottomEdge = -Infinity;
      previous.boxes.forEach(function (box) { if (box.page === previous.last) previousEnd = Math.max(previousEnd, box.end); });
      measurement.boxes.forEach(function (box) { top = Math.min(top, box.start); bottomEdge = Math.max(bottomEdge, box.end); });
      if (!isFinite(previousEnd) || !isFinite(top)) return null;
      var start = previousEnd + 2 * lead + (sentence.breakClass === BLOCK_BREAK ? sentence.gapBefore + sentence.blockInset : 0);
      return { previousEnd: previousEnd, start: start, end: start + bottomEdge - top + sentence.endInset };
    }
    function change(sentence, on) {
      setBreak(sentence, on);
      if (!changes++) next = before;
    }
    function requireBreak(sentence) {
      sentence.required = true;
      if (sentence.dropped) sentence.settled = true;
    }
    // WebView 133 makes a paragraph's first line taller when it carries ruby, but places it as
    // if it were not: the line overhangs the end of its page, or its ruby stays at the end of
    // one page while its text opens the next. A forced break right after such a line skips a
    // page, and one inside it leaves the ruby behind. Returns that line at a sentence's first
    // or last text on a page; the page it starts on must keep earlier content.
    function isText(box) { return box.end - box.start >= natural.textSize * 0.75; }
    function strandedLine(boxes, page, last) {
      function textOn(onPage) {
        return boxes.filter(function (box) { return box.page === onPage && isText(box); });
      }
      var text = textOn(page), keep = page;
      if (!text.length && !last) text = textOn(++page);
      if (!text.length) return null;
      var start = last ? -Infinity : Infinity, end = -Infinity;
      text.forEach(function (box) { start = last ? Math.max(start, box.start) : Math.min(start, box.start); });
      text.forEach(function (box) { if (Math.abs(box.start - start) < 1) end = Math.max(end, box.end); });
      // No line that fits ends below the bottom: plain lines set it.
      return page !== keep || end > bottom + 0.01 ? { page: page, keep: keep, start: start } : null;
    }
    // The sentence that opens the line, from a sentence on it backwards.
    function lineOpener(from, line) {
      var opener = -1;
      for (var at = from; at >= Math.max(0, from - 15); at--) {
        var candidate = sentences[at], placed = actual[at], onLine = false, earlier = false, earlierPage = false;
        if (!candidate.lines.length) continue;
        if (!placed || !placed.boxes) return null;
        placed.boxes.forEach(function (box) {
          if (!isText(box)) return;
          if (box.page === line.page && Math.abs(box.start - line.start) < 1) onLine = true;
          else if (box.page < line.page) earlier = earlierPage = true;
          else if (box.page === line.page && box.start < line.start) earlier = true;
        });
        if (!onLine) break;
        if (hasBreak(candidate) || isOversized(candidate) || earlierPage) return null;
        opener = at;
        if (earlier) break;
      }
      if (opener < 0) return null;
      // The page the line starts on keeps what comes before the opener.
      for (var previous = opener - 1; previous >= 0 && !sentences[previous].lines.length; previous--);
      if (previous >= 0 && !actual[previous]) return null;
      return leavesBlankPage(line.keep, previous >= 0 ? actual[previous].last : -1) ? null : sentences[opener];
    }
    function continueLines(sentence) {
      // A sentence longer than a page continues line by line.
      rewrap = null;
      sentence.lines.forEach(function (line) {
        if (line[1] > pageTop + bottom + tolerance) pageTop = line[0] - lead;
      });
    }
    // A page that starts at a sentence. A forced break in mid-line starts that sentence on a
    // new line, so the rest of its paragraph rewraps and can close up by a line.
    function anchor(sentence) {
      pageTop = sentence.flowStart - sentence.inset;
      var offset = sentence.breakClass === MARKER_BREAK && hasBreak(sentence) ? sentence.inlineStart : 0;
      rewrap = offset > tolerance && sentence.firstLine !== null && natural.lineFill > 0
        ? { run: sentence.run, line: sentence.firstLine, offset: offset, tail: 0 } : null;
    }
    // Lines a position moves up once its paragraph rewraps; rounded towards keeping the line,
    // since an early break only shortens a page while a late one costs another pass.
    function closedLines(line, inline) {
      if (line === null) return 0;
      var lines = line - rewrap.line, fill = natural.lineFill;
      return Math.max(0, lines - Math.floor((lines * fill + inline - rewrap.offset + natural.textSize) / fill));
    }
    for (var index = resume.index; index < sentences.length; index++) {
      var sentence = sentences[index], measurement = actual[index];
      if (!measurement || !isFinite(measurement.first)) continue;
      if (!changes) {
        before = { index: index, page: page, pageTop: pageTop, nextMedia: nextMedia,
          rewrap: rewrap && { run: rewrap.run, line: rewrap.line, offset: rewrap.offset, tail: rewrap.tail } };
      }
      var start = sentence.flowStart, end = sentence.flowEnd + sentence.endInset;
      if (rewrap && rewrap.run !== sentence.run) {
        pageTop += rewrap.tail;
        rewrap = null;
      }
      if (rewrap) {
        start -= closedLines(sentence.firstLine, sentence.inlineStart) * natural.line;
        rewrap.tail = closedLines(sentence.lastLine, sentence.inlineEnd - tolerance) * natural.line;
        end -= rewrap.tail;
      }
      while (nextMedia < natural.media.length && natural.media[nextMedia][0] < start) {
        var item = natural.media[nextMedia++];
        if (!synced && item[1] > pageTop + geometry.capacity + tolerance) pageTop = item[0];
      }
      var fits = end <= pageTop + bottom + tolerance;
      var fitsWithRoom = end + natural.line <= pageTop + bottom;
      var fitsPage = !isOversized(sentence) && end - start <= bottom - sentence.inset + tolerance;
      var crosses = measurement.first !== measurement.last;
      // A required break opening a page that holds less than half a page is stale. One is
      // dropped per correction; later ones still stop the estimate so that it settles. A break
      // the layout required again after one was dropped is kept: dropping it again would only
      // repeat the same two passes.
      var stale = sentence.required && !sentence.settled && !droppedStale && fitsWithRoom && start - pageTop < bottom / 2;
      var previousLast = page;
      if (synced) {
        if (crosses && !hasBreak(sentence) && !isOversized(sentence) && leavesBlankPage(measurement.first, previousLast)) {
          sentence.start.dataset.oversized = 'true';
          continueLines(sentence);
          page = measurement.last;
        } else if (crosses && hasBreak(sentence)) {
          // An oversized sentence needs ordinary continuation, not a blank initial page.
          change(sentence, false);
          sentence.start.dataset.oversized = 'true';
          synced = false;
          continueLines(sentence);
        } else if (crosses && !isOversized(sentence)) {
          var line = strandedLine(measurement.boxes, measurement.first, false);
          var opener = (line && lineOpener(index, line)) || sentence;
          change(opener, true);
          requireBreak(opener);
          synced = false;
          anchor(opener);
        } else if (measurement.first > page && hasBreak(sentence) && leavesBlankPage(measurement.first - 1, previousLast)) {
          var previousBoxes = actual[index - 1] && actual[index - 1].boxes;
          var overhang = previousBoxes && strandedLine(previousBoxes, previousLast, true);
          var opening = overhang && lineOpener(index - 1, overhang);
          change(sentence, false);
          sentence.required = false;
          synced = false;
          if (opening) {
            change(opening, true);
            requireBreak(opening);
            anchor(opening);
          } else {
            sentence.start.dataset.oversized = 'true';
            continueLines(sentence);
          }
        } else if (measurement.first > page) {
          // A page left less than half full by the break after it is checked on the real layout,
          // since the estimate can be off by more than the line it keeps in hand.
          var joined = hasBreak(sentence) && !sentence.required ? placeWithoutBreak(sentence, measurement, actual[index - 1]) : null;
          var short = !!joined && joined.previousEnd < bottom / 2 && joined.end <= bottom + tolerance;
          if (hasBreak(sentence) && (sentence.required ? stale : fitsWithRoom || short)) {
            change(sentence, false);
            droppedStale = sentence.required;
            sentence.dropped = sentence.dropped || sentence.required;
            sentence.required = false;
            synced = false;
            // Keep estimating from where the real layout puts this sentence on that page.
            if (short) pageTop = start - joined.start;
          } else {
            anchor(sentence);
            page = measurement.first;
            if (crosses) { continueLines(sentence); page = measurement.last; }
          }
        } else if (crosses) {
          continueLines(sentence);
          page = measurement.last;
        }
      } else if (hasBreak(sentence) && (sentence.required ? !stale : !fitsWithRoom && fitsPage)) {
        synced = true;
        droppedStale = false;
        anchor(sentence);
        page = measurement.first;
        if (crosses) { continueLines(sentence); page = measurement.last; }
      } else if (fits) {
        if (hasBreak(sentence)) {
          change(sentence, false);
          if (sentence.required) droppedStale = sentence.dropped = true;
          sentence.required = false;
        }
      } else if (fitsPage) {
        change(sentence, true);
        anchor(sentence);
      } else {
        if (hasBreak(sentence)) { change(sentence, false); sentence.required = false; }
        continueLines(sentence);
      }
    }
    return next;
  }
  function placeSentenceBreaks(sentences, context) {
    var geometry = columnGeometry(context);
    if (!(geometry.capacity > 0) || !(context.pageSize > 0)) return;
    var media = Array.from(document.querySelectorAll(MEDIA)).filter(function (element) {
      return getComputedStyle(element).display.indexOf('inline') !== 0;
    });
    // Natural margins between paragraphs, read before any break truncates or clears them, and
    // the padding that closes the paragraph before.
    sentences.forEach(function (sentence, index) {
      var previous = sentences[index - 1];
      sentence.gapBefore = sentence.opensBlock && previous && previous.block !== sentence.block
        ? Math.max(0, blockMargin(previous.block, true, context.vertical), blockMargin(sentence.block, false, context.vertical)) +
          blockInset(previous.block, true, context.vertical)
        : 0;
      sentence.blockInset = sentence.breakClass === BLOCK_BREAK ? blockInset(sentence.block, false, context.vertical) : 0;
      // A paragraph's closing padding stays on the page of its last line.
      var following = sentences[index + 1];
      sentence.endInset = !following || following.block !== sentence.block ? blockInset(sentence.block, true, context.vertical) : 0;
    });
    var natural = naturalFlow(sentences, context, geometry, media);
    var passes = 0, resume = { index: 0, page: -1, pageTop: 0, nextMedia: 0, rewrap: null };
    while (passes < MAX_PASSES && (resume = planPass(sentences, context, geometry, natural, media, resume))) passes++;
    if (resume) {
      // The estimate kept disagreeing with the layout. Finish exactly, one page at a time from
      // where it last changed: drop its later estimates, then break at each crossing sentence.
      var scroll = context.vertical ? context.scrollEl.scrollTop : context.scrollEl.scrollLeft;
      var deadline = Date.now() + FALLBACK_MILLIS;
      for (var index = resume.index; index < sentences.length; index++) setBreak(sentences[index], false);
      for (var guard = 0, from = resume.index; from >= 0 && guard < FALLBACK_LAYOUTS && Date.now() < deadline; guard++) {
        var settled = -1, previousLast = -1, blank = false, illustrated = mediaPages(media, context, geometry);
        for (index = Math.max(0, from - 1); index < sentences.length && settled < 0; index++) {
          var sentence = sentences[index];
          if (!sentence.lines.length) continue;
          var measurement = measure(sentence, context, geometry, scroll, false);
          if (!isFinite(measurement.first)) continue;
          if (index >= from && !isOversized(sentence) && measurement.first !== measurement.last) {
            settled = index;
            // Breaking would leave the page it starts on blank, as in the passes above.
            blank = previousLast < measurement.first && !illustrated[measurement.first] && !hasBreak(sentence);
          }
          previousLast = measurement.last;
        }
        if (settled >= 0) {
          sentence = sentences[settled];
          if (blank) {
            sentence.start.dataset.oversized = 'true';
          } else if (hasBreak(sentence)) {
            setBreak(sentence, false);
            sentence.start.dataset.oversized = 'true';
          } else {
            setBreak(sentence, true);
          }
        }
        from = settled;
        passes++;
      }
    }
    park();
    window.hoshiTextLayout.passes = passes;
  }
  // Breaks are an enhancement: if placing them fails, the chapter reads in its natural flow.
  function placeBreaksSafely(sentences, reader) {
    sentences.forEach(function (sentence) {
      setBreak(sentence, false);
      delete sentence.start.dataset.oversized;
      sentence.required = sentence.dropped = sentence.settled = false;
    });
    try {
      placeSentenceBreaks(sentences, reader.getScrollContext());
    } catch (error) {
      sentences.forEach(function (sentence) { setBreak(sentence, false); });
      if (window.console) console.error('hoshiTextLayout', error);
    }
    park();
  }
  function translationButtons() {
    return Array.from(document.querySelectorAll('.hoshi-tl')).map(function (button) { return button.dataset.tl || ''; }).join('|');
  }
  // The reading position as the count of characters before the page, like a saved bookmark.
  function charactersBeforePage(reader) {
    var walker = reader.createWalker(), node, total = 0;
    while ((node = walker.nextNode())) total += reader.countChars(node.textContent);
    return Math.round(reader.calculateProgress() * total);
  }
  function showCharacter(reader, count) {
    var context = reader.getScrollContext(), walker = reader.createWalker(), node, running = 0;
    while ((node = walker.nextNode())) {
      var length = reader.countChars(node.textContent);
      if (running + length > count) {
        var text = node.textContent, offset = reader.textOffsetForCharCount(node, count - running), range = document.createRange();
        range.setStart(node, offset);
        range.setEnd(node, Math.min(text.length, offset + String.fromCodePoint(text.codePointAt(offset)).length));
        var rect = reader.getRect(range), scroll = reader.getPagePosition(context);
        reader.setPagePosition(context, reader.alignToPage(context, (context.vertical ? rect.top : rect.left) + scroll));
        return;
      }
      running += length;
    }
  }
  function visibleText() { return runs().map(function (run) { return run.text; }).join(''); }
  // What the breaks were placed for: the page box and how the body text's font renders. A web
  // font that finishes loading after the layout changes it.
  var fontProbe = null;
  function layoutSignature(reader) {
    var style = getComputedStyle(document.body);
    fontProbe = fontProbe || document.createElement('canvas').getContext('2d');
    var signature = [reader.pageWidth, reader.pageHeight, document.body.clientWidth, document.body.clientHeight,
      style.paddingTop, style.paddingRight, style.paddingBottom, style.paddingLeft, style.fontSize, style.lineHeight];
    if (fontProbe) {
      fontProbe.font = style.fontStyle + ' ' + style.fontWeight + ' ' + style.fontSize + ' ' + style.fontFamily;
      var metrics = fontProbe.measureText('永あア漢字。「」Aa1');
      signature.push(metrics.width, metrics.fontBoundingBoxAscent, metrics.fontBoundingBoxDescent);
    }
    return signature.join('|');
  }
  var textBefore = null;
  window.hoshiTextLayout = {
    prepare: function (reader, paginated) {
      if (this.prepared) return;
      this.prepared = true;
      this.paginated = paginated;
      textBefore = visibleText();
      wrapWords();
      this.sentences = paginated ? sentenceAnchors() : [];
      this.buttons = translationButtons();
      if (!paginated) return;
      placeBreaksSafely(this.sentences, reader);
      this.signature = layoutSignature(reader);
      this.watch(reader);
    },
    // The characters before the shown page, read before the buttons are added to it.
    position: function (reader) { return this.prepared && this.paginated ? charactersBeforePage(reader) : null; },
    // Places the breaks again and shows the page holding the character at [position].
    relayout: function (reader, position) {
      if (position == null) position = charactersBeforePage(reader);
      placeBreaksSafely(this.sentences, reader);
      this.signature = layoutSignature(reader);
      reader.paginationMetrics = null;
      showCharacter(reader, position);
    },
    // Sentence translation buttons can arrive after the breaks were placed; each takes room in
    // a line. Places the breaks again for the new buttons and shows the page holding the
    // character at [position], the reader's place before the buttons moved the text.
    refresh: function (reader, position) {
      if (!this.prepared || !this.paginated || translationButtons() === this.buttons) return false;
      this.buttons = translationButtons();
      this.relayout(reader, position);
      return true;
    },
    // Breaks placed for one layout leave short pages in another: places them again when the
    // page box or the body text's font no longer match the layout they were placed for.
    revalidate: function (reader) {
      if (!this.prepared || !this.paginated || layoutSignature(reader) === this.signature) return false;
      this.relayout(reader);
      return true;
    },
    // Checks again whenever a font finishes loading: the layout can start before the reader's
    // web font has loaded. A new viewport reloads the chapter instead.
    watch: function (reader) {
      var layout = this, pending = null;
      if (!document.fonts || !document.fonts.addEventListener) return;
      document.fonts.addEventListener('loadingdone', function () {
        if (pending !== null) return;
        pending = setTimeout(function () { pending = null; layout.revalidate(reader); }, 100);
      });
    },
    // Checked on demand: reading the whole chapter again is only needed for verification.
    get textPreserved() { return textBefore !== null && textBefore === visibleText(); }
  };
})();
