// JS-движок скриптов: state, expressions, утилиты.

const String questHtmlJsEngine = r'''
// ===== State =====
var quest = null;
try { quest = JSON.parse(document.getElementById('quest-data').textContent); }
catch (e) {
  document.body.innerHTML =
    '<div style="padding:24px;color:#ff6b6b">Не удалось загрузить квест: ' + e + '</div>';
  throw e;
}
var SCRIPTS = quest.scripts || {};
var NODES = quest.nodes || {};

var resCache = {};
function getResUrl(resId) {
  if (!resId) return null;
  if (resCache[resId]) return resCache[resId];
  var el = document.getElementById(resId);
  if (!el) return null;
  var b64 = el.textContent.trim();
  var mime = el.getAttribute('data-mime') || 'application/octet-stream';
  try {
    var bin = atob(b64), len = bin.length, bytes = new Uint8Array(len);
    for (var i = 0; i < len; i++) bytes[i] = bin.charCodeAt(i);
    var url = URL.createObjectURL(new Blob([bytes], { type: mime }));
    resCache[resId] = url;
    return url;
  } catch (e) { return null; }
}

var state = {
  variables: Object.assign({}, quest.variables || {}),
  tables: JSON.parse(JSON.stringify(quest.tables || {}))
};
function getVariable(n) {
  return Object.prototype.hasOwnProperty.call(state.variables, n) ? state.variables[n] : null;
}
function setVariable(n, v) { state.variables[n] = v; }
function getTable(n) { return state.tables[n] || null; }
function setTable(n, t) { state.tables[n] = t; }

// ===== Helpers =====
function toBool(v) {
  if (typeof v === 'boolean') return v;
  if (typeof v === 'number') return v !== 0;
  if (v == null) return false;
  var s = String(v).trim().toLowerCase();
  if (!s || s === 'null' || s === 'false') return false;
  return true;
}
function toNum(v) {
  if (typeof v === 'number') return v;
  if (typeof v === 'boolean') return v ? 1 : 0;
  if (v == null) return null;
  var n = Number(v); return isNaN(n) ? null : n;
}
function valuesEqual(a, b) {
  if (a == null && b == null) return true;
  if (a == null || b == null) {
    var nn = a == null ? b : a;
    if (typeof nn === 'string') {
      var t = nn.trim().toLowerCase();
      if (!t || ['ничего','nothing','none','null','пусто','нет'].indexOf(t) >= 0) return true;
    }
    return false;
  }
  var an = toNum(a), bn = toNum(b);
  if (an !== null && bn !== null) return an === bn;
  return String(a).trim() === String(b).trim();
}
function stripParens(expr) {
  var e = expr.trim();
  while (e.length > 1 && e.charAt(0) === '(' && e.charAt(e.length - 1) === ')') {
    var depth = 0, wraps = true, inQ = false, qc = '';
    for (var i = 0; i < e.length; i++) {
      var c = e.charAt(i);
      if (inQ) { if (c === qc && e.charAt(i - 1) !== '\\') inQ = false; continue; }
      if (c === "'" || c === '"') { inQ = true; qc = c; continue; }
      if (c === '(') depth++;
      if (c === ')') depth--;
      if (depth === 0 && i < e.length - 1) { wraps = false; break; }
    }
    if (!wraps) break;
    e = e.substring(1, e.length - 1).trim();
  }
  return e;
}
function findTopOp(expr, op) {
  var inQ = false, qc = '', bd = 0, pd = 0;
  for (var i = 0; i <= expr.length - op.length; i++) {
    var c = expr.charAt(i);
    if (inQ) { if (c === qc && expr.charAt(i - 1) !== '\\') inQ = false; continue; }
    if (c === "'" || c === '"') { inQ = true; qc = c; continue; }
    if (c === '[') { bd++; continue; }
    if (c === ']') { bd = Math.max(0, bd - 1); continue; }
    if (c === '(') { pd++; continue; }
    if (c === ')') { pd = Math.max(0, pd - 1); continue; }
    if (bd === 0 && pd === 0 && expr.substr(i, op.length) === op) return i;
  }
  return -1;
}
function compareValues(l, r, op) {
  if (op === '==') return valuesEqual(l, r);
  if (op === '!=') return !valuesEqual(l, r);
  var ln = toNum(l), rn = toNum(r);
  if (ln !== null && rn !== null) {
    if (op === '>') return ln > rn;
    if (op === '<') return ln < rn;
    if (op === '>=') return ln >= rn;
    if (op === '<=') return ln <= rn;
  }
  var ls = String(l == null ? '' : l), rs = String(r == null ? '' : r);
  var cmp = ls.localeCompare(rs);
  if (op === '>') return cmp > 0;
  if (op === '<') return cmp < 0;
  if (op === '>=') return cmp >= 0;
  if (op === '<=') return cmp <= 0;
  return false;
}
function manualDeepLookup(expr) {
  if (!expr) return null;
  var i = 0;
  while (i < expr.length) {
    var c = expr.charAt(i);
    if (c === '[' || c === '.') break;
    i++;
  }
  var baseName = expr.substring(0, i).trim();
  if (!baseName) return null;
  var cur, tbl = getTable(baseName), tableRoot = tbl;
  if (tbl) cur = tbl.data;
  else cur = getVariable(baseName);
  if (cur == null) return null;
  while (i < expr.length) {
    var c2 = expr.charAt(i);
    if (c2 === '.') {
      i++;
      var s = i;
      while (i < expr.length && expr.charAt(i) !== '[' && expr.charAt(i) !== '.') i++;
      var key = expr.substring(s, i).trim();
      if (!key) return null;
      if (cur && typeof cur === 'object' && !Array.isArray(cur)) cur = cur[key];
      else return null;
      tableRoot = null;
    } else if (c2 === '[') {
      i++;
      var start = i, endIdx = -1, inQ = false, qc = '';
      while (i < expr.length) {
        var cc = expr.charAt(i);
        if (inQ) { if (cc === qc && expr.charAt(i - 1) !== '\\') inQ = false; }
        else {
          if (cc === '"' || cc === "'") { inQ = true; qc = cc; }
          else if (cc === ']') { endIdx = i; break; }
        }
        i++;
      }
      if (endIdx < 0) return null;
      var content = expr.substring(start, endIdx).trim();
      i = endIdx + 1;
      if ((content.charAt(0) === '"' && content.charAt(content.length - 1) === '"') ||
          (content.charAt(0) === "'" && content.charAt(content.length - 1) === "'")) {
        var key2 = content.substring(1, content.length - 1);
        if (tableRoot && tableRoot.columns && tableRoot.columns.indexOf(key2) >= 0) {
          // Колонка сетки: следующий числовой индекс — 1-based, как в ядре.
          var vals = (tableRoot.rows || []).map(function(r) { return r[key2]; });
          vals.__mndColumn = true;
          cur = vals;
          tableRoot = null;
        } else if (tableRoot && tableRoot.rowNames && tableRoot.rowNames.indexOf(key2) >= 0) {
          var ri2 = tableRoot.rowNames.indexOf(key2);
          cur = (tableRoot.rows || [])[ri2] || null;
          tableRoot = null;
        } else if (cur && typeof cur === 'object' && !Array.isArray(cur)) {
          cur = cur[key2];
        } else return null;
      } else {
        var idx = parseInt(content, 10);
        if (!isNaN(idx)) {
          if (cur && cur.__mndColumn) {
            if (idx < 1 || idx > cur.length) return null;
            cur = cur[idx - 1];
          } else if (Array.isArray(cur) && idx >= 0 && idx < cur.length) cur = cur[idx];
          else return null;
        } else {
          var kv = evalExpr(content);
          if (cur && cur.__mndColumn) {
            var ci = typeof kv === 'number' ? kv : parseInt(String(kv), 10);
            if (isNaN(ci) || ci < 1 || ci > cur.length) return null;
            cur = cur[ci - 1];
          } else if (Array.isArray(cur)) {
            var ii = typeof kv === 'number' ? kv : parseInt(String(kv), 10);
            if (isNaN(ii) || ii < 0 || ii >= cur.length) return null;
            cur = cur[ii];
          } else if (cur && typeof cur === 'object') {
            cur = cur[kv] != null ? cur[kv] : cur[String(kv)];
          } else return null;
        }
      }
    } else {
      if (c2.trim() === '') { i++; continue; }
      return null;
    }
    if (cur == null) return null;
  }
  return cur;
}
function resolveInlineToken(token) {
  if (Object.prototype.hasOwnProperty.call(state.variables, token)) return state.variables[token];
  var t = getTable(token);
  if (t) return t.data;
  return manualDeepLookup(token);
}
function toExprLiteral(v) {
  if (v == null) return 'null';
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  return "'" + String(v).replace(/'/g, "\\'") + "'";
}
function resolveInlinePlaceholders(expr) {
  return expr.replace(/\{([^{}]+)\}/g, function(_, token) {
    var t = token.trim();
    if (!t) return 'null';
    var v = resolveInlineToken(t);
    return toExprLiteral(v);
  });
}
function evalArith(expr) {
  try {
    var f = new Function('"use strict"; return (' + expr + ');');
    return f();
  } catch (e) { return null; }
}
// Схлопывание лишних фигурных скобок: {{X}} → {X}, X}} {Y} → X} {Y}.
function normalizeBraces(text) {
  var s = String(text);
  if (s.indexOf('{{') === -1 && s.indexOf('}}') === -1) return s;
  var pos;
  while ((pos = s.indexOf('{{')) !== -1) {
    if (pos + 2 < s.length && s.charAt(pos + 2) === '}') break; // маркер {}
    s = s.substring(0, pos) + s.substring(pos + 1);
  }
  var out = '';
  var i = 0;
  while (i < s.length) {
    if (s.charAt(i) === '}' && s.charAt(i + 1) === '}') {
      var next = s.charAt(i + 2);
      if (i + 2 >= s.length || next === '{' || next === ' ' || next === '\n' || next === '\t') {
        out += '}';
        i += 2;
        continue;
      }
    }
    out += s.charAt(i);
    i++;
  }
  return out;
}
function splitArgs(raw) {
  var out = [], depth = 0, start = 0, inQ = false, qc = '';
  for (var i = 0; i < raw.length; i++) {
    var c = raw.charAt(i);
    if (inQ) { if (c === qc && raw.charAt(i - 1) !== '\\') inQ = false; continue; }
    if (c === '"' || c === "'") { inQ = true; qc = c; continue; }
    if (c === '(' || c === '[') depth++;
    else if (c === ')' || c === ']') depth--;
    else if (c === ',' && depth === 0) {
      out.push(raw.substring(start, i).trim());
      start = i + 1;
    }
  }
  out.push(raw.substring(start).trim());
  return out.filter(function(x) { return x !== ''; });
}
function unquote(raw) {
  var s = String(raw == null ? '' : raw).trim();
  if (s.length >= 2 &&
      ((s.charAt(0) === '"' && s.charAt(s.length - 1) === '"') ||
       (s.charAt(0) === "'" && s.charAt(s.length - 1) === "'"))) {
    return s.substring(1, s.length - 1);
  }
  return s;
}
function tableArg(raw) {
  var name = unquote(raw);
  var t = getTable(name);
  if (t) return t;
  var v = evalExpr(raw);
  if (typeof v === 'string') return getTable(v);
  return null;
}
function tableValue(t, col, row) {
  if (!t || !t.rows) return null;
  if (typeof row === 'string') {
    var rn = t.rowNames || [];
    var ri = rn.indexOf(row);
    if (ri < 0) return null;
    row = ri + 1;
  }
  var n = Number(row);
  if (!isFinite(n) || n < 1 || n > t.rows.length) return null;
  return t.rows[n - 1][col];
}
function tableColumn(t, col) {
  return (t && t.rows ? t.rows.map(function(r) { return r[col]; }) : []);
}
function tableNumbers(t, col) {
  return tableColumn(t, col).map(function(v) {
    var n = Number(v);
    return (v === null || v === '' || isNaN(n)) ? null : n;
  }).filter(function(n) { return n !== null; });
}
function evalFunction(name, rawArgs) {
  var args = splitArgs(rawArgs || '');
  var fn = name.toLowerCase();
  if (fn === 'length' || fn === 'len') {
    var v = evalExpr(args[0]);
    if (typeof v === 'string') return v.length;
    if (Array.isArray(v)) return v.length;
    if (v && typeof v === 'object') return Object.keys(v).length;
    return 0;
  }
  if (fn === 'split') {
    var text = evalExpr(args[0]);
    var sep = evalExpr(args[1]);
    return String(text == null ? '' : text).split(String(sep == null ? ' ' : sep));
  }
  if (fn === 'join') {
    var arr = evalExpr(args[0]);
    var sep2 = evalExpr(args[1]);
    return Array.isArray(arr) ? arr.join(String(sep2 == null ? ',' : sep2)) : '';
  }
  if (fn === 'contains') {
    var hay = evalExpr(args[0]), needle = evalExpr(args[1]);
    if (Array.isArray(hay)) return hay.some(function(x) { return valuesEqual(x, needle); });
    return String(hay == null ? '' : hay).indexOf(String(needle == null ? '' : needle)) >= 0;
  }
  if (fn === 'upper' || fn === 'uppercase') return String(evalExpr(args[0]) || '').toUpperCase();
  if (fn === 'lower' || fn === 'lowercase') return String(evalExpr(args[0]) || '').toLowerCase();
  if (fn === 'trim') return String(evalExpr(args[0]) || '').trim();
  if (fn === 'number' || fn === 'to_number' || fn === 'tonumber') return toNum(evalExpr(args[0]));
  if (fn === 'int' || fn === 'to_int') { var ni = toNum(evalExpr(args[0])); return ni == null ? null : Math.trunc(ni); }
  if (fn === 'float') return toNum(evalExpr(args[0]));
  if (fn === 'round') { var nr = toNum(evalExpr(args[0])); return nr == null ? null : Math.round(nr); }
  if (fn === 'floor') { var nf = toNum(evalExpr(args[0])); return nf == null ? null : Math.floor(nf); }
  if (fn === 'ceil') { var nc = toNum(evalExpr(args[0])); return nc == null ? null : Math.ceil(nc); }
  if (fn === 'abs') { var na = toNum(evalExpr(args[0])); return na == null ? null : Math.abs(na); }
  if (fn === 'min' || fn === 'max') {
    var nums = args.map(function(a) { return toNum(evalExpr(a)); }).filter(function(n) { return n !== null; });
    if (!nums.length) return null;
    return fn === 'min' ? Math.min.apply(null, nums) : Math.max.apply(null, nums);
  }
  if (fn === 'table_cell') {
    var t1 = tableArg(args[0]), col1 = evalExpr(args[1]);
    return tableValue(t1, String(col1 == null ? '' : col1), evalExpr(args[2]));
  }
  if (fn === 'table_column') {
    var t2 = tableArg(args[0]), col2 = evalExpr(args[1]);
    return tableColumn(t2, String(col2 == null ? '' : col2));
  }
  if (fn === 'table_columns') {
    var t3 = tableArg(args[0]);
    return t3 && t3.columns ? t3.columns.slice() : [];
  }
  if (fn === 'table_rows') {
    var t4 = tableArg(args[0]);
    return t4 && t4.rows ? t4.rows.length : 0;
  }
  if (fn === 'table_row') {
    var t5 = tableArg(args[0]), row5 = evalExpr(args[1]);
    if (!t5 || !t5.rows) return null;
    var n5 = typeof row5 === 'string'
        ? (t5.rowNames || []).indexOf(row5) + 1
        : Number(row5);
    if (!isFinite(n5) || n5 < 1 || n5 > t5.rows.length) return null;
    return t5.rows[n5 - 1];
  }
  if (fn === 'table_text') {
    var t6 = tableArg(args[0]);
    if (!t6 || !t6.columns) return '';
    var lines = [t6.columns.join('\t')];
    (t6.rows || []).forEach(function(r) {
      lines.push(t6.columns.map(function(c) { return String(r[c] == null ? '' : r[c]); }).join('\t'));
    });
    return lines.join('\n');
  }
  if (fn === 'table_sum' || fn === 'table_avg' || fn === 'table_min' || fn === 'table_max') {
    var t7 = tableArg(args[0]), col7 = evalExpr(args[1]);
    var vals7 = tableNumbers(t7, String(col7 == null ? '' : col7));
    if (!vals7.length) return null;
    if (fn === 'table_sum') return vals7.reduce(function(a, b) { return a + b; }, 0);
    if (fn === 'table_avg') return vals7.reduce(function(a, b) { return a + b; }, 0) / vals7.length;
    return fn === 'table_min' ? Math.min.apply(null, vals7) : Math.max.apply(null, vals7);
  }
  if (fn === 'table_find' || fn === 'table_where' || fn === 'table_has') {
    var t8 = tableArg(args[0]), col8 = evalExpr(args[1]), val8 = evalExpr(args[2]);
    var found = [];
    (t8 && t8.rows ? t8.rows : []).forEach(function(r, i) {
      if (valuesEqual(r[String(col8 == null ? '' : col8)], val8)) found.push(i + 1);
    });
    if (fn === 'table_has') return found.length > 0;
    if (fn === 'table_find') return found.length ? found[0] : null;
    return found;
  }
  return null;
}

function evalExpr(input) {
  if (input == null) return null;
  var expr = normalizeBraces(input).trim();
  if (!expr) return null;
  var low = expr.toLowerCase();
  if (low === 'null') return null;
  if (low === 'true') return true;
  if (low === 'false') return false;
  expr = stripParens(expr);
  var exact = expr.match(/^\{([^{}]+)\}$/);
  if (exact) {
    var t = exact[1].trim();
    if (t) {
      var r = resolveInlineToken(t);
      if (r != null) return r;
    }
  }
  if (expr.charAt(0) === '!' && expr.substr(0, 2) !== '!=') {
    return !toBool(evalExpr(expr.substring(1)));
  }
  var orPos = findTopOp(expr, '||');
  if (orPos !== -1) {
    var L1 = evalExpr(expr.substring(0, orPos));
    var R1 = evalExpr(expr.substring(orPos + 2));
    return toBool(L1) || toBool(R1);
  }
  var andPos = findTopOp(expr, '&&');
  if (andPos !== -1) {
    var L2 = evalExpr(expr.substring(0, andPos));
    var R2 = evalExpr(expr.substring(andPos + 2));
    return toBool(L2) && toBool(R2);
  }
  var cmps = ['==','!=','>=','<=','>','<'];
  for (var i = 0; i < cmps.length; i++) {
    var op = cmps[i];
    var idx = findTopOp(expr, op);
    if (idx === -1) continue;
    var L = evalExpr(expr.substring(0, idx));
    var R = evalExpr(expr.substring(idx + op.length));
    return compareValues(L, R, op);
  }
  var call = expr.match(/^([A-Za-z_][A-Za-z0-9_]*)\(([\s\S]*)\)$/);
  if (call) {
    var fv = evalFunction(call[1], call[2]);
    if (fv != null) return fv;
  }
  if (expr.indexOf('{') >= 0) {
    expr = resolveInlinePlaceholders(expr);
    var l2 = expr.toLowerCase();
    if (l2 === 'null') return null;
    if (l2 === 'true') return true;
    if (l2 === 'false') return false;
  }
  if (/[+\-*/%]/.test(expr.replace(/^[+\-]/, ''))) {
    var r2 = evalArith(expr);
    if (r2 != null) return r2;
  }
  var deep = manualDeepLookup(expr);
  if (deep != null) return deep;
  var num = Number(expr);
  if (!isNaN(num)) return num;
  if ((expr.charAt(0) === "'" && expr.charAt(expr.length - 1) === "'") ||
      (expr.charAt(0) === '"' && expr.charAt(expr.length - 1) === '"')) {
    return expr.substring(1, expr.length - 1);
  }
  if (expr.indexOf('[') >= 0 || expr.indexOf(']') >= 0) return null;
  return expr;
}
''';
