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
// Kept boring on purpose: AngularJS 1.x, array-notation DI, ES5-ish JS.
// ============================================================
angular.module('beamng.apps')
.directive('phoneCameraApp', ['$interval', 'bngApi', function ($interval, bngApi) {
  return {
    restrict: 'E',
    replace: true,
    templateUrl: 'modules/apps/phoneCamera/app.html',
    link: function (scope, element, attrs) {

      // Lua expression: nil-safe so a not-yet-loaded extension yields null.
      var STATUS_EXPR =
        '(extensions.phoneCamera and extensions.phoneCamera.getUiStatus ' +
        'and extensions.phoneCamera.getUiStatus()) or nil';

      var destroyed = false;

      scope.s = null;               // latest raw status snapshot from Lua
      scope.conn = { label: 'CONNECTING...', cls: 'grey' };
      scope.ctrlReady = false;      // control models seeded from first poll?
      scope.ctrl = {                // input models (app owns these after seed)
        enabled: true,
        positionEnabled: true,
        positionScale: 1.0,
        smoothingTau: 0.06
      };

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
        scope.s = d || null;
        scope.conn = computeConn(d);
        // Seed the control inputs once from real Lua state, then let the app
        // own them (so polling never fights a slider mid-drag).
        if (d && !scope.ctrlReady) {
          scope.ctrl.enabled = !!d.enabled;
          scope.ctrl.positionEnabled = !!d.positionEnabled;
          scope.ctrl.positionScale = d.positionScale;
          scope.ctrl.smoothingTau = d.smoothingTau;
          scope.ctrlReady = true;
        }
      }

      function poll() {
        bngApi.engineLua(STATUS_EXPR, function (data) {
          // Callback fires outside Angular's digest — schedule the update.
          scope.$evalAsync(function () { applyData(data); });
        });
      }

      // ---- controls (fire-and-forget engineLua) ----
      scope.recenter = function () {
        bngApi.engineLua('extensions.phoneCamera.recenter()');
      };
      scope.applyEnabled = function () {
        bngApi.engineLua('extensions.phoneCamera.setEnabled(' +
          (scope.ctrl.enabled ? 'true' : 'false') + ')');
      };
      scope.applyPosition = function () {
        bngApi.engineLua('extensions.phoneCamera.setPositionEnabled(' +
          (scope.ctrl.positionEnabled ? 'true' : 'false') + ')');
      };
      scope.applyScale = function () {
        var v = Number(scope.ctrl.positionScale);
        if (!isFinite(v)) { return; }
        bngApi.engineLua('extensions.phoneCamera.setPositionScale(' + v + ')');
      };
      scope.applySmoothing = function () {
        var v = Number(scope.ctrl.smoothingTau);
        if (!isFinite(v)) { return; }
        bngApi.engineLua('extensions.phoneCamera.setSmoothing(' + v + ')');
      };

      poll();                              // immediate first read
      var poller = $interval(poll, 250);   // ~4 Hz

      scope.$on('$destroy', function () {
        destroyed = true;
        if (poller) { $interval.cancel(poller); poller = null; }
      });
    }
  };
}]);
