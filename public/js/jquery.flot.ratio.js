var FlotRatio = (function () {
    function init(plot) {
        plot.hooks.processOptions.push(processOptions);
    }

    function processOptions(plot, options) {
        plot.ratioCategoryNames = [];

        if (options.series.ratio && options.series.ratio.show) {
            $.extend(options.series.bars, {
                show: true,
                horizontal: true,
                align: 'center',
                barWidth: options.series.ratio.barWidth || 0.6
            });

            var xaxis = options.xaxes[options.series.xaxis - 1 || 0];
            $.extend(xaxis, {
                tickFormatter: xaxisTickFormatter(xaxis.tickFormatter)
            });

            var yaxis = options.yaxes[options.series.yaxis - 1 || 0];
            $.extend(yaxis, {
                // Invert order so that rows are ordered (from top to bottom)
                // in the way we received them.
                transform: function (y) { return -y; },
                ticks: plot.ratioCategoryNames
            });

            plot.hooks.processRawData.push(processRawData);
            plot.hooks.processDatapoints.push(processDatapoints);
        }
    }

    function processRawData(plot, series, datapoints) {
        series.data = $.map(series.data, function (d) {
            return [[d[0], Math.log(d[1] / d[2]) / Math.log(2)]];
        });
        fixXaxis(series.data, plot.getOptions());
        fixYaxis(series.data, plot.ratioCategoryNames);
    }

    function processDatapoints(plot, series, datapoints) {
        var swapped = [], points = datapoints.points;

        for (var i = 0, len = points.length; i < len; i += datapoints.format.length) {
            swapped.push(points[i + 1]);
            swapped.push(points[i]);
            swapped.push(points[i + 2]);
        }

        datapoints.points = swapped;
    }

    function xaxisTickFormatter(oldFormatter) {
        return function (val, axis) {
            val = Math.pow(2, val) + "&thinsp;x";
            return oldFormatter ? oldFormatter(val, axis) : val;
        };
    }

    function fixXaxis(data, options) {
        var extent = data.reduce(function(max, arr) { 
            return Math.max(max, Math.abs(arr[1])); 
        }, 1);
        console.log(extent);
        options.xaxes[0].min = -extent;
        options.xaxes[0].max = extent;
    }

    function fixYaxis(data, yaxisTicks) {
        var i, len;
        for (i = 0, len = data.length; i < len; i += 1) {
            yaxisTicks.push([i, data[i][0]]);
        }

        for (var i = 0, len = data.length; i < len; i += 1) {
            data[i][0] = i;
        }
    }

    return {
        init: init
    }
}());

(function ($) {
    $.plot.plugins.push({
        init: FlotRatio.init,
        name: "Ratio",
        version: "0.0.1"
    });
})(jQuery);