(function ($) {
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
                fill: 1.0,
                barWidth: options.series.ratio.barWidth || 0.7
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

    function processRawData(plot, series, data, datapoints) {
        series.data = $.map(data, function (d) {
            return [[d[0], Math.log(d[1] / d[2]) / Math.log(2)]];
        });

        adjustXExtent(series.data, plot.getOptions());
        addMeanLine(series.data, plot.getOptions());
        extractYTicks(series.data, plot.ratioCategoryNames);
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
            val = "&times;" + Math.pow(2, -val).toPrecision(2);
            return oldFormatter ? oldFormatter(val, axis) : val;
        };
    }

    function adjustXExtent(data, options) {
        // TODO: Builtin reduce requires a recent browser.
        var extent = data.reduce(function(max, arr) {
            return Math.max(max, Math.abs(arr[1]));
        }, 1);
        options.xaxes[0].min = -extent;
        options.xaxes[0].max = extent;
    }

    function addMeanLine(data, options) {
        // TODO: Builtin reduce requires a recent browser.
        var sum = data.reduce(function(sum, arr) {
            return sum + arr[1];
        }, 0);
        var mean = sum / data.length;
        // TODO: Don't overwrite existing options here.
        options.grid.markings = [
            {
                color: '#811',
                lineWidth: 1,
                xaxis: {from: mean, to: mean}
            },
            {
                color: '#999',
                lineWidth: 1,
                xaxis: {from: 0.0, to: 0.0}
            }
        ];
    }

    function extractYTicks(data, yaxisTicks) {
        var i, len;
        for (i = 0, len = data.length; i < len; i += 1) {
            yaxisTicks.push([i, data[i][0]]);
        }

        for (var i = 0, len = data.length; i < len; i += 1) {
            data[i][0] = i;
        }
    }

    $.plot.plugins.push({
        init: init,
        name: 'ratio',
        version: '0.0.1'
    });
})(jQuery);
