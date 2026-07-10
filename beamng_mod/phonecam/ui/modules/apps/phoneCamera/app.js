// ============================================================
// Phone Camera — in-game UI app
//
// A draggable HUD widget (UI Apps menu) that polls the phoneCamera GE
// extension ~4 Hz for a live status snapshot and offers basic controls,
// so the user no longer needs the console.
//
// Data flow (verified against BeamNG/ui beamngApi.js):
//   bngApi.engineLua(luaExpr, cb) runs `encodeJson(luaExpr)` in GE Lua and
//   injects the result straight into bngApiCallback(id, <json>), so `cb`
//   receives an ALREADY-DESERIALIZED JS value (object / null) — no
//   JSON.parse. We call extensions.phoneCamera.getUiStatus(), guarded so
//   the expression returns nil (-> JS null) when the extension isn't
//   loaded yet. Fire-and-forget controls call engineLua without a callback.
//
// TEMPLATE: kept INLINE (not templateUrl). A relative templateUrl of
//   'modules/apps/phoneCamera/app.html' does not resolve in the BeamNG UI
//   app host and left the panel blank. With replace:true the template must
//   have a SINGLE root element; the scoped <style> lives nested INSIDE that
//   root .pcam div (AngularJS tolerates this — it is what the old app.html
//   already did). app.html was deleted so the template has one source.
//
// Kept boring on purpose: AngularJS 1.x, array-notation DI, ES5-ish JS
// (no template literals / arrow fns).
// ============================================================
angular.module('beamng.apps')
.directive('phoneCameraApp', [function () {

  // Human-readable hold-mode names, indexed by mode 0..3.
  var HOLD_NAMES = ['Landscape', 'Portrait', 'Upside-down', 'Landscape-R'];

  var TEMPLATE = [
'<div class="pcam">',
'  <style>',
'    .pcam {',
'      width: 100%; height: 100%; box-sizing: border-box;',
'      padding: 8px 9px; overflow: auto;',
'      background: rgba(18, 20, 24, 0.88);',
'      color: #d8dde3;',
'      font-family: \'Segoe UI\', Arial, sans-serif;',
'      font-size: 11px; line-height: 1.35;',
'      border-radius: 4px;',
'      -webkit-user-select: none; user-select: none;',
'    }',
'    .pcam .num, .pcam .val {',
'      font-family: \'Consolas\', \'Courier New\', monospace;',
'      color: #eef2f6;',
'    }',
'    .pcam .hdr {',
'      display: flex; align-items: center; justify-content: space-between;',
'      margin-bottom: 6px;',
'    }',
'    .pcam .title {',
'      font-weight: 700; letter-spacing: 0.5px; font-size: 11px;',
'      color: #9aa4af; text-transform: uppercase;',
'    }',
'    .pcam .badge {',
'      font-family: \'Consolas\', \'Courier New\', monospace;',
'      font-size: 10px; font-weight: 700;',
'      padding: 2px 6px; border-radius: 3px; white-space: nowrap;',
'    }',
'    .pcam .badge.green { background: #1e5b2f; color: #7ff0a0; }',
'    .pcam .badge.amber { background: #6b5410; color: #ffd873; }',
'    .pcam .badge.red   { background: #6b1e1e; color: #ff9a9a; }',
'    .pcam .badge.grey  { background: #333941; color: #aab3bd; }',
'    .pcam .row {',
'      display: flex; justify-content: space-between; align-items: baseline;',
'      padding: 1px 0;',
'    }',
'    .pcam .row .k { color: #8b95a0; }',
'    .pcam .sec {',
'      margin: 6px 0 2px; padding-top: 5px;',
'      border-top: 1px solid rgba(255,255,255,0.08);',
'      color: #6f7982; font-size: 9px; letter-spacing: 0.6px;',
'      text-transform: uppercase;',
'    }',
'    .pcam .tag {',
'      font-family: \'Consolas\', \'Courier New\', monospace;',
'      font-size: 10px; padding: 1px 5px; border-radius: 3px;',
'      background: #2a2f36; color: #9aa4af;',
'    }',
'    .pcam .tag.on { background: #244a63; color: #8fd0ff; }',
'    .pcam .err { color: #ff9a9a; }',
'    .pcam .muted { color: #6f7982; }',
'    .pcam button.recenter {',
'      width: 100%; margin: 4px 0 2px;',
'      padding: 6px; border: none; border-radius: 3px; cursor: pointer;',
'      background: #2e6ea6; color: #fff; font-weight: 700; font-size: 11px;',
'    }',
'    .pcam button.recenter:hover { background: #367fbf; }',
'    .pcam button.recenter:active { background: #285f8f; }',
'    .pcam button.hold {',
'      border: none; border-radius: 3px; cursor: pointer;',
'      padding: 3px 8px; font-size: 10px; font-weight: 700;',
'      font-family: \'Consolas\', \'Courier New\', monospace;',
'      background: #3a4048; color: #cdd6df;',
'    }',
'    .pcam button.hold:hover { background: #454c55; }',
'    .pcam button.hold:active { background: #313740; }',
'    .pcam .ctl {',
'      display: flex; align-items: center; justify-content: space-between;',
'      padding: 3px 0;',
'    }',
'    .pcam .ctl label { color: #b7c0c9; cursor: pointer; }',
'    .pcam .ctl input[type="range"] { flex: 1; margin: 0 8px; min-width: 60px; }',
'    .pcam .ctl .val { min-width: 40px; text-align: right; }',
'    .pcam input[type="checkbox"] { cursor: pointer; }',
'  </style>',
'',
'  <div class="hdr">',
'    <span class="title">Phone Cam</span>',
'    <span class="badge" ng-class="conn.cls">{{ conn.label }}</span>',
'  </div>',
'',
'  <!-- Live status (guarded: null until the extension answers) -->',
'  <div ng-if="s">',
'    <div class="row">',
'      <span class="k">rotation</span>',
'      <span><span class="num">{{ s.rotRate | number:0 }}</span> <span class="muted">/s</span></span>',
'    </div>',
'    <div class="row">',
'      <span class="k">filter tick / applied</span>',
'      <span>',
'        <span class="num">{{ s.filterTickRate | number:0 }}</span>',
'        <span class="muted">/</span>',
'        <span class="num">{{ s.filterAppliedRate | number:0 }}</span>',
'        <span class="muted">/s</span>',
'      </span>',
'    </div>',
'    <div class="row" ng-if="s.deltaAngle != null">',
'      <span class="k">delta angle</span>',
'      <span class="num">{{ s.deltaAngle | number:1 }}&deg;</span>',
'    </div>',
'    <div class="row" ng-if="s.posDelta">',
'      <span class="k">pos delta (m)</span>',
'      <span class="num">{{ s.posDelta.x | number:2 }} {{ s.posDelta.y | number:2 }} {{ s.posDelta.z | number:2 }}</span>',
'    </div>',
'    <div class="row">',
'      <span class="k">camera path</span>',
'      <span class="tag" ng-class="{on: s.isFreeCamera}">{{ s.isFreeCamera ? \'FREE CAM\' : \'filter\' }}</span>',
'    </div>',
'',
'    <div class="sec">datagrams</div>',
'    <div class="row">',
'      <span class="k">json / osc rot / pos</span>',
'      <span class="num">{{ s.dgJson }} / {{ s.dgOscRot }} / {{ s.dgOscPos }}</span>',
'    </div>',
'    <div class="row">',
'      <span class="k">osc other / unknown</span>',
'      <span class="num">{{ s.dgOscOther }} / {{ s.dgUnknown }}</span>',
'    </div>',
'    <div class="row">',
'      <span class="k">ports json / osc</span>',
'      <span class="num">',
'        {{ s.jsonPort }}<span class="muted" ng-if="!s.jsonOpen"> x</span> /',
'        {{ s.oscPort }}<span class="muted" ng-if="!s.oscOpen"> x</span>',
'      </span>',
'    </div>',
'',
'    <div class="row err" ng-if="s.rotFailsTotal > 0">',
'      <span class="k">rot fails</span>',
'      <span class="num">{{ s.rotFailsTotal }}',
'        <span class="muted">(t{{ s.rotFailsTags }} s{{ s.rotFailsShort }} n{{ s.rotFailsNonfinite }} q{{ s.rotFailsNorm }})</span>',
'      </span>',
'    </div>',
'  </div>',
'',
'  <div ng-if="!s" class="muted" style="padding:6px 0;">Waiting for extension...</div>',
'',
'  <!-- Controls -->',
'  <div class="sec">controls</div>',
'  <button class="recenter" ng-click="recenter()">RECENTER</button>',
'',
'  <div class="ctl">',
'    <label><input type="checkbox" ng-model="ctrl.enabled" ng-change="applyEnabled()"> Enabled</label>',
'    <label><input type="checkbox" ng-model="ctrl.positionEnabled" ng-change="applyPosition()"> Position</label>',
'  </div>',
'',
'  <div class="sec">orientation fix</div>',
'  <button class="recenter" ng-click="calibrate()">{{ calibLabel }}</button>',
'  <div class="muted" ng-if="s.calibStep > 0">{{ calibHint }}</div>',
'  <div class="ctl">',
'    <span class="k">hold</span>',
'    <button class="hold" ng-click="cycleHold()">{{ holdName }}</button>',
'    <label><input type="checkbox" ng-model="mirror" ng-change="applyMirror()"> Mirror</label>',
'  </div>',
'',
'  <div class="ctl">',
'    <span class="k">scale</span>',
'    <input type="range" min="0.5" max="10" step="0.1"',
'           ng-model="ctrl.positionScale" ng-change="applyScale()">',
'    <span class="val">{{ ctrl.positionScale | number:1 }}x</span>',
'  </div>',
'',
'  <div class="ctl">',
'    <span class="k">smooth</span>',
'    <input type="range" min="0.01" max="0.5" step="0.01"',
'           ng-model="ctrl.smoothingTau" ng-change="applySmoothing()">',
'    <span class="val">{{ ctrl.smoothingTau | number:2 }}s</span>',
'  </div>',
'</div>'
  ].join('\n');

  // Shape matched to a verified stock app from the user's game version
  // (ClutchThermalDebug): controller-style directive, restrict 'EA',
  // scope: true. Template stays INLINE (stock apps use templateUrl with an
  // absolute '/ui/...' path; inline avoids path resolution entirely).
  return {
    restrict: 'EA',
    replace: true,
    scope: true,
    template: TEMPLATE,
    controller: ['$log', '$scope', '$interval', 'bngApi', function ($log, $scope, $interval, bngApi) {

      // Lua expression: nil-safe so a not-yet-loaded extension yields null.
      var STATUS_EXPR =
        '(extensions.phoneCamera and extensions.phoneCamera.getUiStatus ' +
        'and extensions.phoneCamera.getUiStatus()) or nil';

      var destroyed = false;

      $scope.s = null;               // latest raw status snapshot from Lua
      $scope.conn = { label: 'CONNECTING...', cls: 'grey' };
      $scope.ctrlReady = false;      // slider models seeded from first poll?
      $scope.ctrl = {                // input models (app owns these after seed)
        enabled: true,
        positionEnabled: true,
        positionScale: 1.0,
        smoothingTau: 0.06
      };

      // Hold/Mirror mirror Lua state EVERY poll (unlike the sliders): a mode
      // change auto-recenters in Lua, so the UI must always reflect the truth.
      $scope.holdMode = 1;
      $scope.holdName = HOLD_NAMES[1];
      $scope.mirror = false;

      // Calibration wizard: button label + hint follow Lua's calibStep.
      var CALIB_LABELS = [
        'CALIBRATE AXES',            // step 0: idle
        'CAPTURED - PITCH UP, PRESS',    // after step 1
        'CAPTURED - GO NEUTRAL, PRESS',  // after step 2
        'CAPTURED - TURN LEFT, PRESS'    // after step 3
      ];
      var CALIB_HINTS = [
        '',
        'Hold the phone pitched UP ~45 deg, then press the button again.',
        'Return the phone to your neutral filming pose, then press again.',
        'Hold the phone turned LEFT ~45 deg, then press to finish.'
      ];
      $scope.calibLabel = CALIB_LABELS[0];
      $scope.calibHint = '';

      function computeConn(d) {
        if (!d) { return { label: 'EXTENSION NOT LOADED', cls: 'grey' }; }
        if (!d.enabled) { return { label: 'DISABLED', cls: 'grey' }; }
        var rate = d.rotRate || 0;
        if (rate > 5) {
          return { label: 'STREAMING ' + Math.round(rate) + '/s', cls: 'green' };
        }
        if (d.jsonOpen || d.oscOpen) {
          return { label: 'WAITING FOR PHONE', cls: 'amber' };
        }
        return { label: 'SOCKETS CLOSED', cls: 'red' };
      }

      function applyData(d) {
        if (destroyed) { return; }
        $scope.s = d || null;
        $scope.conn = computeConn(d);
        // Seed the slider inputs once from real Lua state, then let the app
        // own them (so polling never fights a slider mid-drag).
        if (d && !$scope.ctrlReady) {
          $scope.ctrl.enabled = !!d.enabled;
          $scope.ctrl.positionEnabled = !!d.positionEnabled;
          $scope.ctrl.positionScale = d.positionScale;
          $scope.ctrl.smoothingTau = d.smoothingTau;
          $scope.ctrlReady = true;
        }
        // Hold/Mirror track Lua state on every poll.
        if (d && typeof d.holdMode === 'number') {
          $scope.holdMode = d.holdMode;
          $scope.holdName = HOLD_NAMES[d.holdMode] || ('mode ' + d.holdMode);
        }
        if (d) { $scope.mirror = !!d.mirrorRotation; }
        if (d && typeof d.calibStep === 'number') {
          var st = Math.max(0, Math.min(3, d.calibStep));
          $scope.calibLabel = st === 0 && d.calibrated
            ? 'RE-CALIBRATE AXES (set)'
            : CALIB_LABELS[st];
          $scope.calibHint = CALIB_HINTS[st];
        }
      }

      function poll() {
        bngApi.engineLua(STATUS_EXPR, function (data) {
          // Callback fires outside Angular's digest — schedule the update.
          $scope.$evalAsync(function () { applyData(data); });
        });
      }

      // ---- controls (fire-and-forget engineLua) ----
      $scope.calibrate = function () {
        bngApi.engineLua('extensions.phoneCamera.calibrate()');
        poll();  // refresh the step label promptly
      };
      $scope.recenter = function () {
        bngApi.engineLua('extensions.phoneCamera.recenter()');
      };
      $scope.applyEnabled = function () {
        bngApi.engineLua('extensions.phoneCamera.setEnabled(' +
          ($scope.ctrl.enabled ? 'true' : 'false') + ')');
      };
      $scope.applyPosition = function () {
        bngApi.engineLua('extensions.phoneCamera.setPositionEnabled(' +
          ($scope.ctrl.positionEnabled ? 'true' : 'false') + ')');
      };
      $scope.applyScale = function () {
        var v = Number($scope.ctrl.positionScale);
        if (!isFinite(v)) { return; }
        bngApi.engineLua('extensions.phoneCamera.setPositionScale(' + v + ')');
      };
      $scope.applySmoothing = function () {
        var v = Number($scope.ctrl.smoothingTau);
        if (!isFinite(v)) { return; }
        bngApi.engineLua('extensions.phoneCamera.setSmoothing(' + v + ')');
      };
      // Cycle 0 -> 1 -> 2 -> 3 -> 0; Lua auto-recenters on the change.
      $scope.cycleHold = function () {
        var next = ((Number($scope.holdMode) || 0) + 1) % 4;
        bngApi.engineLua('extensions.phoneCamera.setHoldMode(' + next + ')');
      };
      $scope.applyMirror = function () {
        bngApi.engineLua('extensions.phoneCamera.setMirror(' +
          ($scope.mirror ? 'true' : 'false') + ')');
      };

      poll();                              // immediate first read
      var poller = $interval(poll, 250);   // ~4 Hz

      $scope.$on('$destroy', function () {
        destroyed = true;
        if (poller) { $interval.cancel(poller); poller = null; }
      });
    }]
  };
}]);
