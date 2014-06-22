function dashRenderComparePlot(
    container,
    benchmarkNames,
    baseMeans,
    baseStdDevs,
    targetMeans,
    targetStdDevs
) {
    var ratioData = [];
    var count = benchmarkNames.length;
    for (var i = 0; i < count; ++i) {
        ratioData.push([benchmarkNames[i], baseMeans[i], targetMeans[i]]);
    }
    var series =[{data: ratioData, ratio: {show: true}, color: '#d9230f'}];

    // Unfortunately, we can't move this into the "ratio" plugin, as we need
    // to render the error bars as a new series (otherwise, the "bars" plugin
    // used for drawing will use the added standard deviation value as an
    // additional end point instead of zero).
    if (baseStdDevs.length == count && targetStdDevs.length == count) {
        var errorBarData = [];
        for (var i = 0; i < count; ++i) {
            // The following mirrors the 'ratio' internals. Not pretty, but
            // this way the whole ratio plugin stays reusable.
            var x = Math.log(baseMeans[i] / targetMeans[i]) / Math.log(2);

            // Simple Gaussian error propagation. Meh.
            var xErr = Math.sqrt(
                Math.pow(baseStdDevs[i] / baseMeans[i], 2) +
                Math.pow(targetStdDevs[i] / targetMeans[i], 2)
            ) / Math.log(2);

            errorBarData.push([x, i, xErr]);
        }   
        series.push({
            data: errorBarData,
            points: {
                radius: 0,
                errorbars: 'x',
                xerr: {
                    show: true
                },
                lineWidth: 1,
                shadowSize: 0
            },
            lines: { show: false },
            color: '#333'
        });
    }

    $.plot(container, series);
}
