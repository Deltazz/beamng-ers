angular.module('beamng.apps')
.directive('ersDash', ['$log', function ($log) {
  return {
    templateUrl: '/ui/modules/apps/ERS/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element, attrs) {
      StreamsManager.add(['engineInfo', 'electrics', 'wheelInfo']);

      scope.$on('$destroy', function () {
        $log.debug('<ers-dash> destroyed');
        StreamsManager.remove(['engineInfo', 'electrics']);
      });

      scope.numToBig = '1';
      scope.speed = NaN;

      scope.$on('streamsUpdate', function (event, streams) {
        scope.$evalAsync(function () {
          if (streams.electrics) {
            // Speed
            var ersThrottle = Math.round(streams.electrics.mgukThrottle * 100.0);
            scope.ersThrottle = ersThrottle.toString();
            if (streams.electrics.ers_overtake)
              scope.ersOvertake = "ACTIVE";
            else
              scope.ersOvertake = "";
            scope.ersBattery = (streams.electrics.ers_battery*100.0) | 0;
            if (streams.electrics.ers_strategy == 0)
              scope.ersStrategy = "[" + streams.electrics.ers_strategy + "] CONSERVE";
            else if (streams.electrics.ers_strategy == 1)
              scope.ersStrategy = "[" + streams.electrics.ers_strategy + "] POWER";
            else
              scope.ersStrategy = "[" + streams.electrics.ers_strategy + "] OFF";
          }
        });
      });
    }
  };
}]);