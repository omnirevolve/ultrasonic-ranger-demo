# Usage: gnuplot -persist -e "csv='data.csv'" tools/plot/plot_distances.gp
set datafile separator ","
if (!exists("csv")) csv="data.csv"
set key left top
set xlabel "sample"
set ylabel "distance (m)"
plot csv using 0:2 with lines title "d0", \
     csv using 0:3 with lines title "d1", \
     csv using 0:4 with lines title "d2", \
     csv using 0:5 with lines title "d3", \
     csv using 0:6 with lines title "d4"
