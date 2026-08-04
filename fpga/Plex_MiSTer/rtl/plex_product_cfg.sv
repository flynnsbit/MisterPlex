// Fabric-visible product configuration stamp.
// Forces PRODUCT_NO_STUB / DDR_FRAME_STORE / FABRIC_FRAME_DMA into the netlist
// so a post-fit hierarchy dump can prove the product build options.
// Outputs are constants under `ifdef; kept live via Plex.sv status fold-in.
// FABRIC_FRAME_DMA is research-only until device-proven; product QSF omits it.
module plex_product_cfg (
	output wire product_no_stub,
	output wire ddr_frame_store_en,
	output wire fabric_frame_dma_en
);
`ifdef PRODUCT_NO_STUB
	assign product_no_stub = 1'b1;
`else
	assign product_no_stub = 1'b0;
`endif
`ifdef DDR_FRAME_STORE
	assign ddr_frame_store_en = 1'b1;
`else
	assign ddr_frame_store_en = 1'b0;
`endif
`ifdef FABRIC_FRAME_DMA
	assign fabric_frame_dma_en = 1'b1;
`else
	assign fabric_frame_dma_en = 1'b0;
`endif
endmodule
