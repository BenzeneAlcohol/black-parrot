
module bp_be_mmu_vm_top 
  import bp_common_pkg::*;
  import bp_be_pkg::*;
  import bp_be_rv64_pkg::*;
  import bp_be_dcache_pkg::*;
 #(parameter vaddr_width_p                 = "inv"
   , parameter paddr_width_p               = "inv"
   , parameter asid_width_p                = "inv"
   , parameter branch_metadata_fwd_width_p = "inv"
 
   // ME parameters
   , parameter num_cce_p                 = "inv"
   , parameter num_lce_p                 = "inv"
   , parameter cce_block_size_in_bytes_p = "inv"
   , parameter lce_assoc_p               = "inv"
   , parameter lce_sets_p                = "inv"

   , parameter data_width_p = rv64_reg_data_width_gp

   // Generated parameters
   // D$   
   , localparam lce_data_width_lp = cce_block_size_in_bytes_p*8
   , localparam block_size_in_words_lp = lce_assoc_p // Due to cache interleaving scheme
   , localparam data_mask_width_lp     = (data_width_p >> 3) // Byte mask
   , localparam byte_offset_width_lp   = `BSG_SAFE_CLOG2(data_width_p >> 3)
   , localparam word_offset_width_lp   = `BSG_SAFE_CLOG2(block_size_in_words_lp)
   , localparam block_offset_width_lp  = (word_offset_width_lp + byte_offset_width_lp)
   , localparam index_width_lp         = `BSG_SAFE_CLOG2(lce_sets_p)
   , localparam page_offset_width_lp   = (block_offset_width_lp + index_width_lp)
   , localparam dcache_pkt_width_lp    = `bp_be_dcache_pkt_width(page_offset_width_lp
                                                                 , data_width_p
                                                                 )
   , localparam lce_id_width_lp = `BSG_SAFE_CLOG2(num_lce_p)

   // MMU                                                              
   , localparam mmu_cmd_width_lp  = `bp_be_mmu_cmd_width(vaddr_width_p)
   , localparam mmu_resp_width_lp = `bp_be_mmu_resp_width
   , localparam vtag_width_lp     = vaddr_width_p - page_offset_width_lp
   , localparam ptag_width_lp     = paddr_width_p - page_offset_width_lp
                                                      
   // ME
   , localparam cce_block_size_in_bits_lp = 8 * cce_block_size_in_bytes_p

    , localparam lce_req_width_lp=
      `bp_lce_cce_req_width(num_cce_p, num_lce_p, paddr_width_p, lce_assoc_p, data_width_p)
    , localparam lce_resp_width_lp=
      `bp_lce_cce_resp_width(num_cce_p, num_lce_p, paddr_width_p)
    , localparam lce_data_resp_width_lp=
      `bp_lce_cce_data_resp_width(num_cce_p, num_lce_p, paddr_width_p, lce_data_width_lp)
    , localparam lce_cmd_width_lp=
      `bp_cce_lce_cmd_width(num_cce_p, num_lce_p, paddr_width_p, lce_assoc_p)
    , localparam lce_data_cmd_width_lp=
      `bp_lce_data_cmd_width(num_lce_p, lce_data_width_lp, lce_assoc_p)
   )
  (input                                      clk_i
   , input                                    reset_i
    
   , input [mmu_cmd_width_lp-1:0]             mmu_cmd_i
   , input                                    mmu_cmd_v_i
   , output                                   mmu_cmd_ready_o
    
   , input                                    chk_poison_ex_i
    
   , output [mmu_resp_width_lp-1:0]           mmu_resp_o
   , output                                   mmu_resp_v_o
    
   , output [lce_req_width_lp-1:0]            lce_req_o
   , output                                   lce_req_v_o
   , input                                    lce_req_ready_i
    
   , output [lce_resp_width_lp-1:0]           lce_resp_o
   , output                                   lce_resp_v_o
   , input                                    lce_resp_ready_i                                 
    
   , output [lce_data_resp_width_lp-1:0]      lce_data_resp_o
   , output                                   lce_data_resp_v_o
   , input                                    lce_data_resp_ready_i
    
   , input [lce_cmd_width_lp-1:0]             lce_cmd_i
   , input                                    lce_cmd_v_i
   , output                                   lce_cmd_ready_o

   , input [lce_data_cmd_width_lp-1:0]        lce_data_cmd_i
   , input                                    lce_data_cmd_v_i
   , output                                   lce_data_cmd_ready_o

   , output logic [lce_data_cmd_width_lp-1:0] lce_data_cmd_o
   , output logic                             lce_data_cmd_v_o
   , input                                    lce_data_cmd_ready_i

   , input [lce_id_width_lp-1:0]              dcache_id_i
   );

`declare_bp_be_internal_if_structs(vaddr_width_p
                                   , paddr_width_p
                                   , asid_width_p
                                   , branch_metadata_fwd_width_p
                                   );

`declare_bp_be_mmu_structs(vaddr_width_p, lce_sets_p, cce_block_size_in_bytes_p)
`declare_bp_be_dcache_pkt_s(page_offset_width_lp, data_width_p);
`declare_bp_be_tlb_entry_s(ptag_width_lp);

// Cast input and output ports 
bp_be_mmu_cmd_s        mmu_cmd;
bp_be_mmu_resp_s       mmu_resp;

assign mmu_cmd    = mmu_cmd_i;
assign mmu_resp_o = mmu_resp;


/* Internal connections */
/* TLB ports */
logic                     tlb_en, tlb_miss, tlb_w_v;
logic [vtag_width_lp-1:0] tlb_w_vtag, tlb_miss_vtag;
bp_be_tlb_entry_s         tlb_r_entry, tlb_w_entry;

/* PTW ports */
logic [ptag_width_lp-1:0] base_ppn, ptw_dcache_ptag;
logic                     ptw_dcache_v, ptw_busy;
bp_be_dcache_pkt_s        ptw_dcache_pkt; 

assign base_ppn = 'h80008;    //TODO: pass from upper level modules

/* D-Cache ports*/
bp_be_dcache_pkt_s            dcache_pkt;
logic [data_width_p-1:0] dcache_data;
logic [ptag_width_lp-1:0]     dcache_ptag;
logic                         dcache_ready, dcache_miss_v, dcache_v, dcache_pkt_v, dcache_tlb_miss, dcache_poison;

bp_be_dtlb
  #(.vtag_width_p(vtag_width_lp)
    ,.ptag_width_p(ptag_width_lp)
	,.els_p(16)
  )
  dtlb
  (.clk_i(clk_i)
   ,.reset_i(reset_i)
   ,.en_i(1'b1)
   
   ,.r_v_i(mmu_cmd_v_i)
   ,.r_vtag_i(mmu_cmd.vaddr.tag)
   
   ,.r_v_o()
   ,.r_entry_o(tlb_r_entry)
   
   ,.w_v_i(tlb_w_v)
   ,.w_vtag_i(tlb_w_vtag)
   ,.w_entry_i(tlb_w_entry)
   
   ,.miss_clear_i(1'b0)
   ,.miss_v_o(tlb_miss)
   ,.miss_vtag_o(tlb_miss_vtag)
  );
  
bp_be_ptw
  #(.pte_width_p(bp_sv39_pte_width_gp)
    ,.vaddr_width_p(vaddr_width_p)
    ,.paddr_width_p(paddr_width_p)
    ,.page_offset_width_p(page_offset_width_lp)
    ,.page_table_depth_p(bp_sv39_page_table_depth_gp)
  )
  ptw
  (.clk_i(clk_i)
   ,.reset_i(reset_i)
   ,.base_ppn_i(base_ppn)
   ,.busy_o(ptw_busy)
   
   ,.tlb_miss_v_i(tlb_miss)
   ,.tlb_miss_vtag_i(tlb_miss_vtag)
   
   ,.tlb_w_v_o(tlb_w_v)
   ,.tlb_w_vtag_o(tlb_w_vtag)
   ,.tlb_w_entry_o(tlb_w_entry)

   ,.dcache_v_i(dcache_v)
   ,.dcache_data_i(dcache_data)
   
   ,.dcache_v_o(ptw_dcache_v)
   ,.dcache_pkt_o(ptw_dcache_pkt)
   ,.dcache_ptag_o(ptw_dcache_ptag)
   ,.dcache_rdy_i(dcache_ready)
   ,.dcache_miss_i(dcache_miss_v)
  );

bp_be_dcache 
  #(.data_width_p(data_width_p) 
    ,.sets_p(lce_sets_p)
    ,.ways_p(lce_assoc_p)
    ,.paddr_width_p(paddr_width_p)
    ,.num_cce_p(num_cce_p)
    ,.num_lce_p(num_lce_p)
    )
  dcache
   (.clk_i(clk_i)
    ,.reset_i(reset_i)

    ,.lce_id_i(dcache_id_i)

    ,.dcache_pkt_i(dcache_pkt)
    ,.v_i(dcache_pkt_v)
    ,.ready_o(dcache_ready)

    ,.v_o(dcache_v)
    ,.data_o(dcache_data)

    ,.tlb_miss_i(dcache_tlb_miss)
    ,.ptag_i(dcache_ptag)
    ,.uncached_i(1'b0)                  

    ,.cache_miss_o(dcache_miss_v)
    ,.poison_i(dcache_poison)

    // LCE-CCE interface
    ,.lce_req_o(lce_req_o)
    ,.lce_req_v_o(lce_req_v_o)
    ,.lce_req_ready_i(lce_req_ready_i)

    ,.lce_resp_o(lce_resp_o)
    ,.lce_resp_v_o(lce_resp_v_o)
    ,.lce_resp_ready_i(lce_resp_ready_i)

    ,.lce_data_resp_o(lce_data_resp_o)
    ,.lce_data_resp_v_o(lce_data_resp_v_o)
    ,.lce_data_resp_ready_i(lce_data_resp_ready_i)

    // CCE-LCE interface
    ,.lce_cmd_i(lce_cmd_i)
    ,.lce_cmd_v_i(lce_cmd_v_i)
    ,.lce_cmd_ready_o(lce_cmd_ready_o)

    ,.lce_data_cmd_i(lce_data_cmd_i)
    ,.lce_data_cmd_v_i(lce_data_cmd_v_i)
    ,.lce_data_cmd_ready_o(lce_data_cmd_ready_o)

    ,.lce_data_cmd_o(lce_data_cmd_o)
    ,.lce_data_cmd_v_o(lce_data_cmd_v_o)
    ,.lce_data_cmd_ready_i(lce_data_cmd_ready_i)
    );
    
always_comb 
  begin
    if(ptw_busy) begin
      dcache_pkt = ptw_dcache_pkt;
    end
    else begin
      dcache_pkt.opcode      = bp_be_dcache_opcode_e'(mmu_cmd.mem_op);
      dcache_pkt.page_offset = {mmu_cmd.vaddr.index, mmu_cmd.vaddr.offset};
      dcache_pkt.data        = mmu_cmd.data;
    end
    
    dcache_pkt_v    = (ptw_busy)? ptw_dcache_v : mmu_cmd_v_i;
    dcache_ptag     = (ptw_busy)? ptw_dcache_ptag : tlb_r_entry.ptag;
    dcache_tlb_miss = (ptw_busy)? 1'b0 : tlb_miss;
    dcache_poison   = (ptw_busy)? 1'b0 : chk_poison_ex_i;
    
    mmu_resp.data   = dcache_data;  
    mmu_resp.exception.cache_miss_v = dcache_miss_v;
    mmu_resp.exception.tlb_miss_v = tlb_miss;
  end

// Ready-valid handshakes
assign mmu_resp_v_o    = (ptw_busy)? 1'b0: dcache_v;
assign mmu_cmd_ready_o = dcache_ready & ~dcache_miss_v & ~tlb_miss;

endmodule : bp_be_mmu_vm_top

