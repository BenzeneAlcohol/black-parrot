module bp_sacc_cddip
 import bp_common_pkg::*;
 import bp_common_aviary_pkg::*;
 import bp_be_pkg::*;
 import bp_common_rv64_pkg::*;
 import bp_common_cfg_link_pkg::*;
 import bp_cce_pkg::*;
 import bp_me_pkg::*;
 import bp_be_dcache_pkg::*;  
  #(parameter bp_params_e bp_params_p = e_bp_default_cfg
    `declare_bp_proc_params(bp_params_p)
    `declare_bp_bedrock_lce_if_widths(paddr_width_p, cce_block_width_p, lce_id_width_p, cce_id_width_p, lce_assoc_p, lce)
    `declare_bp_bedrock_mem_if_widths(paddr_width_p, cce_block_width_p, lce_id_width_p, lce_assoc_p, cce)
    , localparam cfg_bus_width_lp= `bp_cfg_bus_width(vaddr_width_p, core_id_width_p, cce_id_width_p, lce_id_width_p, cce_pc_width_p, cce_instr_width_p)
    )
   (
    input                                     clk_i
    , input                                   reset_i

    , input [lce_id_width_p-1:0]              lce_id_i
    
    , input  [cce_mem_msg_width_lp-1:0]       io_cmd_i
    , input                                   io_cmd_v_i
    , output                                  io_cmd_ready_o

    , output [cce_mem_msg_width_lp-1:0]       io_resp_o
    , output logic                            io_resp_v_o
    , input                                   io_resp_yumi_i

    , output [cce_mem_msg_width_lp-1:0]       io_cmd_o
    , output logic                            io_cmd_v_o
    , input                                   io_cmd_yumi_i

    , input [cce_mem_msg_width_lp-1:0]        io_resp_i
    , input                                   io_resp_v_i
    , output                                  io_resp_ready_o
    );


  `declare_bp_bedrock_mem_if(paddr_width_p, cce_block_width_p, lce_id_width_p, lce_assoc_p, cce);
   
  bp_bedrock_cce_mem_msg_s io_resp_cast_o, io_resp_cast_i;
  bp_bedrock_cce_mem_msg_header_s resp_header, cmd_header; 
  bp_bedrock_cce_mem_msg_s io_cmd_cast_i, io_cmd_cast_o;
  bp_bedrock_cce_mem_payload_s mem_cmd_payload;

  assign io_resp_cast_i = io_resp_i;
   

   logic  io_cmd_ready;  
   logic  temp_cmd_v_o;
   
   logic [`N_RBUS_ADDR_BITS-1:0] apb_paddr;
   logic                         apb_psel;
   logic                         apb_penable;
   logic                         apb_pwrite;
   logic [`N_RBUS_DATA_BITS-1:0] apb_pwdata;
   logic [`N_RBUS_DATA_BITS-1:0] apb_prdata;
   logic                         apb_pready;
   logic                         apb_pslverr;

   logic                         ib_tready;
   logic [`AXI_S_TID_WIDTH-1:0]  ib_tid;
   logic [`AXI_S_DP_DWIDTH-1:0]  ib_tdata;
   logic [`AXI_S_TSTRB_WIDTH-1:0] ib_tstrb;
   logic [`AXI_S_USER_WIDTH-1:0]  ib_tuser;
   logic                          ib_tvalid;
   logic                          ib_tlast;


   logic                          ob_tready;
   logic [`AXI_S_TID_WIDTH-1:0]   ob_tid;
   logic [`AXI_S_DP_DWIDTH-1:0]   ob_tdata, temp_ob_tdata;
   logic [`AXI_S_TSTRB_WIDTH-1:0] ob_tstrb;
   logic [`AXI_S_USER_WIDTH-1:0] ob_tuser, prev_ob_tuser;
   logic                         ob_tvalid, prev_ob_tvalid;
   logic                         ob_tlast;


   logic                         sch_update_tready;
   logic [7:0]                   sch_update_tdata;
   logic                         sch_update_tvalid;
   logic                         sch_update_tlast;
   logic [1:0]                   sch_update_tuser;


   logic                         engine_int;
   logic                         engine_idle;
   logic                         key_mode;
   logic                         dbg_cmd_disable;
   logic                         xp9_disable;


   bp_bedrock_cce_mem_payload_s  resp_payload;
   bp_bedrock_msg_size_e         resp_size;
   bp_bedrock_mem_type_e         resp_msg;
   logic [paddr_width_p-1:0]     resp_addr;
   logic [63:0]                  resp_data;
   logic [63:0]                  tlv_type, data_tlv_num;
   logic [63:0]                  resp_ptr;
   logic                         resp_done;
    
   
   bp_local_addr_s           local_addr_li, prev_local_addr_li;
   bp_global_addr_s          global_addr_li;

   assign key_mode = 0;
   assign dbg_cmd_disable = 0;
   assign xp9_disable = 0;
   assign sch_update_tready = 1;
   
   assign io_resp_ready_o = 1'b1;
   assign io_cmd_cast_i = io_cmd_i;
   assign io_resp_o = io_resp_cast_o;
   
   assign global_addr_li = io_cmd_cast_i.header.addr;
   assign local_addr_li = io_cmd_cast_i.header.addr;

   assign resp_header   =  '{msg_type       : resp_msg
                             ,addr          : resp_addr
                             ,payload       : resp_payload
                             ,size          : resp_size  };
   assign io_resp_cast_o = '{header         : resp_header
                             ,data          : resp_data  };
   
   assign apb_paddr= 0;
   assign apb_psel= 1'b1;
   assign apb_penable= io_cmd_v_i & (local_addr_li.dev == '1);
   
   assign apb_pwrite= io_cmd_v_i & (io_cmd_cast_i.header.msg_type.mem == e_bedrock_mem_uc_wr) & (local_addr_li.dev == '1);
   assign apb_pwdata= io_cmd_cast_i.data;

//dma engine
logic           dma_enable;
logic [63:0] dma_address, dma_csr_data, comp_csr_data, spm_data_lo;

logic [63:0]    dma_length, dma_counter, resp_dma_counter, tlv_counter;
logic           dma_start, dma_done, start, resp_start, done_state, dma_type;
assign resp_data = (prev_local_addr_li.dev == 4'd2) ? dma_csr_data : comp_csr_data;
assign dma_enable = io_cmd_v_i & (local_addr_li.dev == 4'd2) & (local_addr_li.nonlocal == 9'd0);//device number 2 is dma

//assign ob_read =  io_cmd_v_i & (local_addr_li.nonlocal != 9'd0) & (io_cmd_cast_i.header.msg_type.mem == e_bedrock_mem_uc_rd);
assign mem_cmd_payload.lce_id = lce_id_i;
assign mem_cmd_payload.uncached = 1'b1;
assign io_cmd_o = io_cmd_cast_o;

typedef enum logic [3:0]{
  RESET
  , WAIT_START
  , FETCH
  , WAIT_RESP
  , DONE_IN
  , READY_OB
  , STORE_RESP
  , WAIT_RESP_O
  , LAST_RESP
  , RESP_DONE
} state_e;
state_e state_r, state_n;
   
//assign ob_tready = 1;   
assign io_cmd_ready_o = (ib_tlast != 1) ? ib_tready : 1 ;   
always_ff @(posedge clk_i) begin

   if(reset_i) begin
     state_r <= RESET;
     dma_counter <= 0;
     resp_dma_counter <= 0;
     data_tlv_num <= 0;
     tlv_counter <= 0;
     dma_start <= 0;
     ib_tvalid      <= 1'b0;
     ib_tdata       <= 64'd0;
     ib_tid         <= 1'b0;
     ib_tlast       <= 1'b0;
   end
   else begin
     state_r <= state_n;
     prev_local_addr_li <= local_addr_li;
     prev_ob_tuser <= ob_tuser;
     prev_ob_tvalid <= ob_tvalid;
     if (io_resp_v_i && (io_resp_cast_i.header.msg_type.mem == e_bedrock_mem_uc_rd))
       begin
        dma_counter <= (state_n >= DONE_IN) ? '0 : dma_counter + 1;
                        //sot-eot                    //eot                                     //sot                       //mot
        ib_tuser     <= (dma_length == 1) ? 64'd3 : ((dma_length-1 == dma_counter) ? 64'd2 : ((dma_counter == 0) ? 64'd1 : 64'd0));
        ib_tvalid    <= 1'b1;
        ib_tlast     <= (tlv_type == 64'd4) & (dma_length-1 == dma_counter);
        ib_tdata     <= io_resp_cast_i.data;
        ib_tid       <=1'b0;
       end
     else if (io_resp_v_i && (io_resp_cast_i.header.msg_type.req == e_bedrock_req_uc_wr))
       begin
          resp_dma_counter <= ((state_r == WAIT_RESP_O) | (state_r == LAST_RESP)) ? resp_dma_counter + 1 : resp_dma_counter;
       end
     else
       ib_tvalid     <= '0;
   end 
   

   if (io_cmd_v_o && (io_cmd_cast_o.header.msg_type.mem == e_bedrock_mem_uc_wr))
     data_tlv_num <= data_tlv_num + 1;
  
   if (ob_tready & (ob_tuser == 1))
     tlv_counter <= tlv_counter + 1;
   
   if (~dma_enable)
      dma_start   <= 0;
   else if (dma_enable & (io_cmd_cast_i.header.msg_type.mem == e_bedrock_mem_uc_wr))
     unique
       case (local_addr_li.addr)
           20'h00000 : dma_address <= io_cmd_cast_i.data;
           20'h00008 : dma_length  <= io_cmd_cast_i.data;
           20'h00010 : dma_start   <= io_cmd_cast_i.data;
           20'h00020 : dma_type    <= io_cmd_cast_i.data;
          default : begin end
       endcase 
   else if (dma_enable & (io_cmd_cast_i.header.msg_type.mem == e_bedrock_mem_uc_rd))
     begin
     unique
       case (local_addr_li.addr)
           20'h00018 : dma_csr_data <= dma_done;
          default : begin end
       endcase
        dma_start   <= 0;
     end
   else
     dma_start   <= 0;
end  
   
always_comb begin
   state_n = state_r;
   case (state_r)
     RESET: begin
        state_n = reset_i ? RESET : WAIT_START;
        dma_done = 0;
        io_cmd_v_o = 1'b0;
        resp_done = 0;
        io_cmd_ready = 1;
        ob_tready = 0;
     end
     WAIT_START: begin
        state_n = dma_start ? FETCH : WAIT_START;
        dma_done = 0;
        io_cmd_v_o = 1'b0;
        resp_done = 0;
        ob_tready = 0;
     end
     FETCH: begin
        state_n = (dma_counter == (dma_length-1)) ? DONE_IN : WAIT_RESP;
        dma_done = 0;
        io_cmd_v_o = 1'b1;
        io_cmd_cast_o.header.payload = mem_cmd_payload;
        io_cmd_cast_o.header.size = 3'b011;//8 byte
        io_cmd_cast_o.header.addr = dma_address + (dma_counter*8);
        io_cmd_cast_o.header.msg_type.mem = e_bedrock_mem_uc_rd;
        resp_done = 0;
        ob_tready = 0;
     end
     WAIT_RESP: begin
        state_n = io_resp_v_i ? FETCH : WAIT_RESP;
        dma_done = 0;
        io_cmd_v_o = 1'b0;
        resp_done = 0;
        ob_tready = 0;
     end
     DONE_IN: begin
        resp_done = 0;
        dma_done = 1;
        io_cmd_v_o = 1'b0;
        state_n = dma_start ? (ib_tlast ? READY_OB : FETCH) : DONE_IN;
        ob_tready = 0;
     end
     READY_OB: begin
        dma_done = 0;
        ob_tready = 1;
        temp_ob_tdata = ob_tdata;
        state_n = ~ob_tvalid ? READY_OB : (~ob_tlast ? STORE_RESP : LAST_RESP);
     end
     STORE_RESP:
       begin
          dma_done = 0;
          ob_tready = 0;
          io_cmd_v_o = (tlv_counter == 2);//1'b1;
          io_cmd_cast_o.data = temp_ob_tdata;
          io_cmd_cast_o.header.payload = mem_cmd_payload;
          io_cmd_cast_o.header.size = 3'b011;//8 byte
          io_cmd_cast_o.header.addr = dma_address + (resp_dma_counter*8);
          io_cmd_cast_o.header.msg_type.mem = e_bedrock_mem_uc_wr;
          state_n = (tlv_counter == 2) ?  WAIT_RESP_O : READY_OB;
       end
     WAIT_RESP_O:
       begin
          dma_done = 0;
          ob_tready = 0;
          io_cmd_v_o = 1'b0;
          state_n = ~io_resp_v_i ? WAIT_RESP_O : (~ob_tlast ? READY_OB : RESP_DONE);
       end
     LAST_RESP:
       begin
          dma_done = 0;
          ob_tready = 0;
          io_cmd_v_o = (tlv_counter == 2);//1'b1;
          io_cmd_cast_o.header.payload = mem_cmd_payload;
          io_cmd_cast_o.header.size = 3'b011;//8 byte
          io_cmd_cast_o.header.addr = dma_address + (resp_dma_counter*8);
          io_cmd_cast_o.header.msg_type.mem = e_bedrock_mem_uc_wr;
          state_n = (tlv_counter == 2) ? WAIT_RESP_O : RESP_DONE;
       end
     RESP_DONE:
       begin
          dma_done = 1;
          ob_tready = 0;
          io_cmd_v_o = 1'b0;
          state_n = (dma_start & ~ib_tlast) ? FETCH : RESP_DONE;
       end
   endcase
end
   
always_ff @(posedge clk_i) 
begin
   if (io_cmd_v_i  & (local_addr_li.dev == 4'd1) & (local_addr_li.nonlocal == 9'd0))
     begin
        resp_size    <= io_cmd_cast_i.header.size;
        resp_payload <= io_cmd_cast_i.header.payload;
        resp_addr    <= io_cmd_cast_i.header.addr;
        resp_msg     <= io_cmd_cast_i.header.msg_type.mem;
        io_resp_v_o  <= 1'b1;
        if ((io_cmd_cast_i.header.msg_type.mem == e_bedrock_mem_uc_wr))
          case (local_addr_li.addr)
            20'h00000 : tlv_type <= io_cmd_cast_i.data;
            default : begin end
          endcase
        else if ((io_cmd_cast_i.header.msg_type.mem == e_bedrock_mem_uc_rd))
          case (local_addr_li.addr)
            20'h00008 : comp_csr_data <= data_tlv_num;
            default : begin end
          endcase
     end 
   else if (io_cmd_v_i  & (local_addr_li.nonlocal != 9'd0)) // if write to buffer yes, but for read we need to wait 
     begin
        resp_size    <= io_cmd_cast_i.header.size;
        resp_payload <= io_cmd_cast_i.header.payload;
        resp_addr    <= io_cmd_cast_i.header.addr;
        resp_msg     <= io_cmd_cast_i.header.msg_type.mem;
        io_resp_v_o  <= 1'b1;
     end
   else if(dma_enable)
     begin
        io_resp_v_o    <= 1'b1;
        resp_size      <= io_cmd_cast_i.header.size;
        resp_payload   <= io_cmd_cast_i.header.payload;
        resp_addr      <= io_cmd_cast_i.header.addr;
        resp_msg       <= io_cmd_cast_i.header.msg_type.mem;
     end
   else
     begin
        io_resp_v_o  <= 1'b0;
     end
end 


assign ib_tstrb  = 8'hff;
   
   cr_cddip#( 
               )
      dut(.ib_tready(ib_tready),
          .ib_tvalid(ib_tvalid),
          .ib_tlast(ib_tlast),
          .ib_tid(ib_tid),
          .ib_tstrb(ib_tstrb),
          .ib_tuser(ib_tuser),
          .ib_tdata(ib_tdata),


          .ob_tready(ob_tready),
          .ob_tvalid(ob_tvalid),
          .ob_tlast(ob_tlast),
          .ob_tid(ob_tid),
          .ob_tstrb(ob_tstrb),
          .ob_tuser(ob_tuser),
          .ob_tdata(ob_tdata),


          .sch_update_tready(sch_update_tready),
          .sch_update_tvalid(sch_update_tvalid),
          .sch_update_tlast(sch_update_tlast),
          .sch_update_tuser(sch_update_tuser),
          .sch_update_tdata(sch_update_tdata),

          
          .apb_paddr(apb_paddr),
          .apb_psel(apb_psel),
          .apb_penable(apb_penable),
          .apb_pwrite(apb_pwrite),
          .apb_pwdata(apb_pwdata),
          .apb_prdata(apb_prdata),
          .apb_pready(apb_pready),
          .apb_pslverr(apb_pslverr),


          .clk(clk_i),
          .rst_n(~reset_i),
          .dbg_cmd_disable (dbg_cmd_disable),
          .xp9_disable (xp9_disable),
          .cddip_int (engine_int),
          .cddip_idle (engine_idle),
          .scan_en(1'b0),
          .scan_mode(1'b0),
          .scan_rst_n(1'b0),


          .ovstb(1'b1),
          .lvm(1'b0),
          .mlvm(1'b0)

          );
          
                                    
  
endmodule

