// Quartus generates only BUILD_DATE here; the parity helper supplies it via -D.
`ifndef BUILD_DATE
`error "The QSF parity helper must supply BUILD_DATE"
`endif
