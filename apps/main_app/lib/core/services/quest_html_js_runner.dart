// JS-исполнитель скриптов: блоки, событийная модель, runScript.

const String questHtmlJsRunner = r'''
// ===== Script execution =====
function resolveEventTypeName(b) {
  var t = (b.eventType || '').toString().trim();
  if (t) return t;
  var title = (b.title || '').toString().trim();
  if (title === 'При запуске квеста') return 'onQuestStart';
  if (title === 'При запуске ноды') return 'onNodeEnter';
  if (title === 'При нажатии') return 'onPress';
  // Диспетчер изменений данных JS-экспорт не исполняет (нет отслеживания
  // правок). Важно, чтобы блок не притворился «при появлении контента» и не
  // сработал раньше времени — он остаётся объявленным и просто не вызывается.
  if (title === 'При изменении данных') return 'onDataChange';
  if (title === 'Функция') return 'function';
  if (b.type === 'event' || title) return 'onContentAppear';
  return null;
}
function resolveBlocksToRun(allBlocks, requestedType, opts) {
  opts = opts || {};
  var fn = opts.functionName || null;
  var cid = opts.contentItemId || null;
  var events = (allBlocks || []).filter(function(b){
    return b && (b.type === 'event' || 'eventType' in b || 'title' in b);
  });
  function targetMatches(b) {
    var t = b.targetContentItemId ? String(b.targetContentItemId) : '';
    var has = !!t;
    if (!cid) return !has;
    return !has || t === cid;
  }
  function functionMatches(b) {
    if (requestedType !== 'function') return true;
    var needed = (fn || 'main').trim();
    var curRaw = b.functionName ? String(b.functionName).trim() : '';
    var cur = curRaw || 'main';
    return cur === needed;
  }
  var matched = events.filter(function(b){
    var typ = resolveEventTypeName(b) || '';
    return typ === requestedType && targetMatches(b) && functionMatches(b);
  });
  if (matched.length > 0) {
    var out = [];
    matched.forEach(function(e){
      (e.children || []).forEach(function(c){ out.push(c); });
    });
    return out;
  }
  if (events.length === 0) {
    // Плоский скрипт без event-обёртки: движок выполняет его блоки целиком.
    if (['onNodeEnter', 'onContentAppear', 'onQuestStart'].indexOf(requestedType) >= 0) {
      return allBlocks;
    }
  }
  return [];
}
function hasExecBlocks(script, eventType, opts) {
  return resolveBlocksToRun(script.blocks || [], eventType, opts).length > 0;
}
function checkEventType(script) {
  var blocks = script.blocks || [];
  for (var i = 0; i < blocks.length; i++) {
    var b = blocks[i];
    if (b && b.type === 'event') {
      var et = resolveEventTypeName(b);
      if (et) return et;
    }
  }
  return 'onContentAppear';
}
function evalCondition(block) {
  var expression;
  if (block.expression) expression = block.expression;
  else {
    var variable = block.variable || '';
    var comparison = block.comparison || '==';
    var value = String(block.value == null ? '0' : block.value);
    var isNumeric = !isNaN(Number(value));
    var isVar = value.charAt(0) === '{' && value.charAt(value.length-1) === '}';
    var needsQuotes = !isNumeric && !isVar && value.charAt(0) !== "'" && value.charAt(0) !== '"';
    var v = needsQuotes ? ("'" + value + "'") : value;
    expression = '{' + variable + '} ' + comparison + ' ' + v;
  }
  var r = evalExpr(expression);
  if (typeof r === 'boolean') return r;
  if (typeof r === 'number') return r !== 0;
  if (typeof r === 'string') return r.length > 0 && r !== 'false';
  return r != null;
}
function parsePath(path) {
  if (!path) return [];
  var keys = [];
  var re = /\.?([a-zA-Zа-яА-ЯёЁ0-9_]+)|\["([^"]+)"\]|\['([^']+)'\]|\[(\d+)\]|'([^']+)'|"([^"]+)"/g;
  var m;
  while ((m = re.exec(path)) !== null) {
    if (m[1] != null) { var n = parseInt(m[1], 10); keys.push(isNaN(n) ? m[1] : n); }
    else if (m[2] != null) keys.push(m[2]);
    else if (m[3] != null) keys.push(m[3]);
    else if (m[4] != null) keys.push(parseInt(m[4], 10));
    else if (m[5] != null) keys.push(m[5]);
    else if (m[6] != null) keys.push(m[6]);
  }
  return keys;
}
function getValueAtPath(root, keys) {
  var cur = root;
  for (var i = 0; i < keys.length; i++) {
    var k = keys[i];
    if (cur && typeof cur === 'object' && !Array.isArray(cur)) cur = cur[k];
    else if (Array.isArray(cur) && typeof k === 'number') {
      if (k < 0 || k >= cur.length) return null;
      cur = cur[k];
    } else return null;
    if (cur == null) return null;
  }
  return cur;
}
function setValueAtPath(root, keys, value) {
  var cur = root;
  for (var i = 0; i < keys.length - 1; i++) {
    var k = keys[i], nk = keys[i + 1];
    if (cur && typeof cur === 'object' && !Array.isArray(cur)) {
      if (!(k in cur) || cur[k] == null) cur[k] = (typeof nk === 'number') ? [] : {};
      cur = cur[k];
    } else if (Array.isArray(cur) && typeof k === 'number') {
      if (k < 0 || k >= cur.length) return;
      cur = cur[k];
    } else return;
  }
  var last = keys[keys.length - 1];
  if (cur && typeof cur === 'object' && !Array.isArray(cur)) cur[last] = value;
  else if (Array.isArray(cur) && typeof last === 'number') {
    if (last >= 0 && last < cur.length) cur[last] = value;
    else if (last === cur.length) cur.push(value);
  }
}
function normalizeScriptId(raw) {
  if (raw == null) return '';
  var v = String(raw).trim();
  if (!v) return '';
  var slash = v.lastIndexOf('/');
  if (slash !== -1) v = v.substring(slash + 1);
  if (v.substr(-5) === '.json') v = v.substring(0, v.length - 5);
  return v;
}

var currentMusic = null;
function stopMusic() {
  if (currentMusic) { try { currentMusic.pause(); } catch(e){} currentMusic = null; }
}

async function execBlock(block) {
  if (!block || typeof block !== 'object') return null;
  var type = block.type;
  if (type === 'assign_variable' || type === 'создать_переменную' || type === 'изменить_переменную') {
    var varName = block.variable;
    var val = evalExpr(block.value);
    var operation = block['операция'];
    if (operation && varName) {
      var cur = getVariable(varName);
      if (cur == null) cur = 0;
      if (operation === 'прибавить') cur = (toNum(cur) || 0) + (toNum(val) || 0);
      else if (operation === 'отнять') cur = (toNum(cur) || 0) - (toNum(val) || 0);
      else cur = val;
      setVariable(varName, cur);
    } else if (varName) setVariable(varName, val);
    return null;
  }
  if (type === 'condition' || type === 'условие') {
    var ok = evalCondition(block);
    var children = ok ? (block.then_blocks || block['если_да'] || [])
                      : (block.else_blocks || block['если_нет'] || []);
    for (var i = 0; i < children.length; i++) {
      var r = await execBlock(children[i]);
      if (r != null) return r;
    }
    return null;
  }
  if (type === 'go_to_node') {
    var rid = block.node_id;
    if (rid == null) return null;
    var expr = String(rid).trim();
    if (expr.charAt(0) === '=') expr = expr.substring(1).trim();
    if (expr) {
      var e = evalExpr(expr);
      var r2 = e != null ? String(e).trim() : '';
      if (r2) return r2;
    }
    return String(rid);
  }
  if (type === 'call_function' || type === 'call_script') {
    var sid = normalizeScriptId(block.function_id || block.script_id);
    if (!sid) return null;
    var nested = SCRIPTS[sid];
    if (!nested) return null;
    var fnEntry = (block.function_entry || 'main').toString().trim() || 'main';
    var candidates = [];
    if (type === 'call_function') candidates.push('function');
    var declared = checkEventType(nested);
    if (candidates.indexOf(declared) < 0) candidates.push(declared);
    ['function','onNodeEnter','onContentAppear','onPress'].forEach(function(e){
      if (candidates.indexOf(e) < 0) candidates.push(e);
    });
    for (var k = 0; k < candidates.length; k++) {
      var ev = candidates[k];
      if (!hasExecBlocks(nested, ev, { functionName: ev === 'function' ? fnEntry : null })) continue;
      var r3 = await runScript(nested, ev, { functionName: ev === 'function' ? fnEntry : null });
      if (r3 != null) return r3;
      break;
    }
    return null;
  }
  if (type === 'table_operation') {
    var opName = block.operation;
    var tblExpr = block.tableName;
    var ev2 = evalExpr(tblExpr);
    var tableName;
    if (ev2 != null && typeof ev2 === 'object') tableName = String(tblExpr);
    else tableName = String(ev2 == null ? 'storage' : ev2);
    var tbl = getTable(tableName);
    if (!tbl) { tbl = { data: {} }; setTable(tableName, tbl); }
    var rawPath = block.path || '';
    // Паритет с ядром: литералы вида "items[0]" evaluator не осиливает и
    // возвращает null — тогда используем сырой путь.
    var evPath = evalExpr(rawPath);
    var pathStr = (evPath == null && String(rawPath).trim() !== '' && String(rawPath) !== 'null')
        ? String(rawPath)
        : String(evPath == null ? '' : evPath);
    var keys = parsePath(pathStr);
    var pathGiven = String(rawPath).trim() !== '';
    if (opName === 'get') {
      var v = getValueAtPath(tbl.data, keys);
      var fallback = ('value' in block) ? evalExpr(block.value) : null;
      var tgt = block.targetVariable;
      var res = (v == null) ? fallback : v;
      if (typeof res === 'string' && (res.indexOf('{') >= 0 || res.indexOf('+') >= 0 || res.indexOf('(') >= 0)) {
        var c2 = evalExpr(res);
        if (c2 != null) res = c2;
      }
      if (tgt) setVariable(tgt, res);
    } else if (opName === 'set') {
      var val2 = evalExpr(block.value);
      // Пустой путь не должен создавать служебный ключ (паритет ядра).
      if (pathGiven && keys.length > 0) setValueAtPath(tbl.data, keys, val2);
    } else if (opName === 'add') {
      var val3 = evalExpr(block.value);
      if (pathGiven && keys.length > 0) {
        var tgt2 = getValueAtPath(tbl.data, keys);
        if (Array.isArray(tgt2)) tgt2.push(val3);
        else if (tgt2 == null) setValueAtPath(tbl.data, keys, [val3]);
      }
    } else if (opName === 'clear') {
      if (keys.length === 0) tbl.data = {};
      else {
        var tgt3 = getValueAtPath(tbl.data, keys);
        if (Array.isArray(tgt3)) tgt3.length = 0;
        else if (tgt3 && typeof tgt3 === 'object') for (var kk in tgt3) delete tgt3[kk];
      }
    } else if (opName === 'remove') {
      // Удаляет ПОСЛЕДНИЙ ключ пути из родителя (паритет ядра).
      if (!pathGiven || keys.length === 0) { /* корень таблицы удалить нельзя */ }
      else {
        var pk = keys.slice(0, -1);
        var parent = getValueAtPath(tbl.data, pk);
        var lk = keys[keys.length - 1];
        var ok = false;
        if (Array.isArray(parent) && typeof lk === 'number') {
          var idx = (lk < 0) ? lk + parent.length : lk;
          if (idx >= 0 && idx < parent.length) { parent.splice(idx, 1); ok = true; }
        } else if (parent && typeof parent === 'object' && !Array.isArray(parent)) {
          var sk = String(lk);
          if (sk in parent) { delete parent[sk]; ok = true; }
        }
        if (ok && pk.length > 0) setValueAtPath(tbl.data, pk, parent);
      }
    } else if (opName === 'remove_value') {
      // Пара к «Добавить»: убирает из списка ПЕРВОЕ совпадение со значением.
      var rv = evalExpr(block.value);
      if (pathGiven && keys.length > 0 && block.value != null && String(block.value).trim() !== '') {
        var rt = getValueAtPath(tbl.data, keys);
        if (Array.isArray(rt)) {
          for (var i2 = 0; i2 < rt.length; i2++) {
            if (valuesEqual(rt[i2], rv)) { rt.splice(i2, 1); break; }
          }
          setValueAtPath(tbl.data, keys, rt);
        }
      }
    } else if (opName === 'contains') {
      var cv = evalExpr(block.value);
      var ct = getValueAtPath(tbl.data, keys);
      var found;
      if (Array.isArray(ct)) found = ct.some(function(x){ return valuesEqual(x, cv); });
      else if (ct && typeof ct === 'object') found = Object.keys(ct).some(function(k){ return valuesEqual(ct[k], cv); });
      else found = (ct != null) && !!valuesEqual(ct, cv);
      setVariable(block.targetVariable || 'result', !!found);
    }
    return null;
  }
  if (type === 'for_each') {
    var tableName5 = String(block.table || block['таблица'] || '').trim();
    var t5 = getTable(tableName5);
    if (!t5 || !t5.rows || !block.children) return null;
    var prefix5 = String(block.var_prefix || block['префикс'] || 'row').trim();
    if (!prefix5) prefix5 = 'row';
    var index5 = String(block.index_variable || block['индекс'] || 'i').trim();
    if (!index5) index5 = 'i';
    var cols5 = t5.columns || [];
    for (var i5 = 0; i5 < t5.rows.length; i5++) {
      setVariable(index5, i5);
      for (var c5 = 0; c5 < cols5.length; c5++) {
        setVariable(prefix5 + '_' + cols5[c5], t5.rows[i5][cols5[c5]]);
      }
      for (var ch5 = 0; ch5 < block.children.length; ch5++) {
        var rr5 = await execBlock(block.children[ch5]);
        if (rr5 != null) return rr5;
      }
    }
    return null;
  }
  if (type === 'wait' || type === 'задержка') {
    var v3 = evalExpr(block.expression || block.milliseconds || '0');
    var ms = (typeof v3 === 'number') ? v3 : parseInt(String(v3), 10) || 0;
    if (ms > 0) await new Promise(function(r){ setTimeout(r, ms); });
    return null;
  }
  if (type === 'play_sound' || type === 'play_music') {
    var resId = block.audio_id || null;
    var loop = !!block.loop;
    var rawVol = evalExpr(block.volume != null ? block.volume : 1);
    var vol = Math.max(0, Math.min(1, typeof rawVol === 'number' ? rawVol : parseFloat(rawVol) || 1));
    // audio_id хранит uuid ассета. В нашем экспорте у нас resId по пути -
    // прямого маппинга нет, но в audioPathToResId положим все известные.
    var url = resId ? getResUrl(resId) : null;
    if (!url && resId) {
      // попробовать как путь к res/audio
      url = getResUrl(audioPathToResId[resId]);
    }
    if (url) {
      try {
        var a = new Audio(url);
        a.volume = vol; a.loop = loop;
        a.play().catch(function(){});
        if (type === 'play_music') { stopMusic(); currentMusic = a; }
      } catch(_){}
    }
    return null;
  }
  if (type === 'stop_sound' || type === 'stop_music') { stopMusic(); return null; }
  if (type === 'set_blur') {
    var rawBlur = evalExpr(block.blur != null ? block.blur : 10);
    var b2 = typeof rawBlur === 'number' ? rawBlur : parseFloat(rawBlur) || 0;
    var bg = document.getElementById('bg-layer');
    if (bg) bg.style.filter = 'blur(' + b2 + 'px)';
    return null;
  }
  return null;
}

var audioPathToResId = {};

async function runScript(script, eventType, opts) {
  opts = opts || {};
  var blocks = resolveBlocksToRun(script.blocks || [], eventType, opts);
  if (!blocks.length) return null;
  var limit = 2000;
  for (var i = 0; i < blocks.length; i++) {
    if (--limit <= 0) break;
    var r = await execBlock(blocks[i]);
    if (r != null) return r;
  }
  return null;
}
''';
