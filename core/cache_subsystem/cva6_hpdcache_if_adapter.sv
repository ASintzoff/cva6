// Copyright 2023 Commissariat a l'Energie Atomique et aux Energies
//                Alternatives (CEA)
//
// Licensed under the Solderpad Hardware License, Version 2.1 (the “License”);
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Authors: Cesar Fuguet
// Date: February, 2023
// Description: Interface adapter for the CVA6 core
//
// Additional contributions by:
// June, 2024 - Yannick Casamatta, Thales
//              OBI Protocol

module cva6_hpdcache_if_adapter
//  Parameters
//  {{{
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter hpdcache_pkg::hpdcache_cfg_t HPDcacheCfg = '0,
    parameter type hpdcache_tag_t = logic,
    parameter type hpdcache_req_offset_t = logic,
    parameter type hpdcache_req_sid_t = logic,
    parameter type hpdcache_req_t = logic,
    parameter type hpdcache_rsp_t = logic,
    parameter type load_req_t = logic,
    parameter type load_rsp_t = logic,
    parameter type obi_store_req_t = logic,
    parameter type obi_store_rsp_t = logic,
    parameter type obi_amo_req_t = logic,
    parameter type obi_amo_rsp_t = logic,
    parameter type obi_load_req_t = logic,
    parameter type obi_load_rsp_t = logic,
    parameter type obi_mmu_ptw_req_t = logic,
    parameter type obi_mmu_ptw_rsp_t = logic,
    parameter type obi_zcmt_req_t = logic,
    parameter type obi_zcmt_rsp_t = logic,
    parameter bit InvalidateOnFlush = 1'b0,
    parameter bit IsLoadPort = 1'b1,
    parameter bit IsMmuPtwPort = 1'b0,
    parameter bit IsZcmtPort = 1'b0
)
//  }}}

//  Ports
//  {{{
(
    //  Clock and active-low reset pins
    input logic clk_i,
    input logic rst_ni,

    //  Port ID
    input hpdcache_req_sid_t hpdcache_req_sid_i,

    //  Request/response ports from/to the CVA6 core
    input  load_req_t        load_req_i,
    output load_rsp_t        load_rsp_o,
    input  obi_store_req_t   obi_store_req_i,
    output obi_store_rsp_t   obi_store_rsp_o,
    input  obi_amo_req_t     obi_amo_req_i,
    output obi_amo_rsp_t     obi_amo_rsp_o,
    input  obi_load_req_t    obi_load_req_i,
    output obi_load_rsp_t    obi_load_rsp_o,
    input  obi_mmu_ptw_req_t obi_mmu_ptw_req_i,
    output obi_mmu_ptw_rsp_t obi_mmu_ptw_rsp_o,
    input  obi_zcmt_req_t    obi_zcmt_req_i,
    output obi_zcmt_rsp_t    obi_zcmt_rsp_o,

    //  Dcache flush signal
    input  logic cva6_dcache_flush_i,
    output logic cva6_dcache_flush_ack_o,

    //  Request port to the L1 Dcache
    output logic                        hpdcache_req_valid_o,
    input  logic                        hpdcache_req_ready_i,
    output hpdcache_req_t               hpdcache_req_o,
    output logic                        hpdcache_req_abort_o,
    output hpdcache_tag_t               hpdcache_req_tag_o,
    output hpdcache_pkg::hpdcache_pma_t hpdcache_req_pma_o,

    //  Response port from the L1 Dcache
    input logic          hpdcache_rsp_valid_i,
    input hpdcache_rsp_t hpdcache_rsp_i
);
  //  }}}

  //  Internal nets and registers
  //  {{{
  typedef enum {
    FLUSH_IDLE,
    FLUSH_PEND
  } flush_fsm_t;

  logic forward_store, forward_amo;
  logic hpdcache_req_is_uncacheable;
  hpdcache_req_t hpdcache_req;
  //  }}}

  //  Request forwarding
  //  {{{
  generate
    //  LOAD request
    //  {{{
    if (IsLoadPort == 1'b1) begin : load_port_gen

      logic [1:0] load_data_size;

      if (CVA6Cfg.XLEN == 64) begin
        assign load_data_size = ariane_pkg::size_gen(hpdcache_req.be);
      end else begin
        assign load_data_size = ariane_pkg::size_gen_32(hpdcache_req.be);
      end

      //    Request forwarding OBI channel A

      assign hpdcache_req.wdata = '0;
      assign hpdcache_req.op = hpdcache_pkg::HPDCACHE_REQ_LOAD;
      assign hpdcache_req.size = load_data_size;
      assign hpdcache_req.sid = hpdcache_req_sid_i;

      assign hpdcache_req.need_rsp = 1'b1;

      assign hpdcache_req_abort_o = load_req_i.kill_req;

      if (CVA6Cfg.MmuPresent) begin
        // When MMu is present request is done in 2 phases, s0: index, s1:tag
        assign hpdcache_req.phys_indexed = 1'b0;
        assign hpdcache_req_valid_o = load_req_i.req;
        assign hpdcache_req.addr_offset = load_req_i.address_index;
        assign hpdcache_req.addr_tag = '0;  // unused on virtually indexed request
        assign hpdcache_req.be = load_req_i.be;
        assign hpdcache_req.tid = load_req_i.aid;
        assign hpdcache_req.pma.uncacheable = 1'b0;  // unused on virtually indexed request
        assign hpdcache_req.pma.io = 1'b0;  // unused on virtually indexed request
        assign hpdcache_req.pma.wr_policy_hint = hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO;  // unused on virtually indexed request

        assign hpdcache_req_pma_o.uncacheable = !obi_load_req_i.a.a_optional.memtype[1];
        assign hpdcache_req_pma_o.io = 1'b0;
        assign hpdcache_req_pma_o.wr_policy_hint = hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO;
        assign hpdcache_req_tag_o = obi_load_req_i.a.addr[CVA6Cfg.DCACHE_TAG_WIDTH     +
                                                                                    CVA6Cfg.DCACHE_INDEX_WIDTH-1 :
                                                                                    CVA6Cfg.DCACHE_INDEX_WIDTH];

        assign obi_load_rsp_o.gnt = 1'b1;  //if hpdcache is always ready to accept tag in s1
        assign load_rsp_o.gnt = hpdcache_req_ready_i;
      end else begin
        // When MMu is not present request is done in 1 phases, s0: index+tag
        assign hpdcache_req.phys_indexed = 1'b1;
        assign hpdcache_req_valid_o = obi_load_req_i.req;
        assign hpdcache_req.addr_offset = obi_load_req_i.a.addr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
        assign hpdcache_req.addr_tag = obi_load_req_i.a.addr[CVA6Cfg.DCACHE_TAG_WIDTH     +
                                                                                    CVA6Cfg.DCACHE_INDEX_WIDTH-1 :
                                                                                    CVA6Cfg.DCACHE_INDEX_WIDTH];
        assign hpdcache_req.be = obi_load_req_i.a.be;
        assign hpdcache_req.tid = obi_load_req_i.a.aid;
        assign hpdcache_req.pma.uncacheable = !obi_load_req_i.a.a_optional.memtype[1];
        assign hpdcache_req.pma.io = 1'b0;
        assign hpdcache_req.pma.wr_policy_hint = hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO;

        assign hpdcache_req_pma_o.uncacheable = '0;  // unused on physically indexed request
        assign hpdcache_req_pma_o.io = '0;  // unused on physically indexed request
        assign hpdcache_req_pma_o.wr_policy_hint = hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO;
        ;  // unused on physically indexed request
        assign hpdcache_req_tag_o = '0;  // unused on physically indexed request

        assign obi_load_rsp_o.gnt = obi_load_req_i.req && hpdcache_req_ready_i;
        assign load_rsp_o.gnt = 1'b0;
      end

      assign obi_load_rsp_o.gntpar = !obi_load_rsp_o.gnt;

      //    Response forwarding OBI channel R

      if (!CVA6Cfg.MmuPresent || (CVA6Cfg.ObiVersion == config_pkg::OBI_NOT_COMPLIANT)) begin

        assign obi_load_rsp_o.rvalid = hpdcache_rsp_valid_i;
        assign obi_load_rsp_o.rvalidpar = !hpdcache_rsp_valid_i;
        assign obi_load_rsp_o.r.rid = hpdcache_rsp_i.tid;
        assign obi_load_rsp_o.r.r_optional.exokay = '0;
        assign obi_load_rsp_o.r.r_optional.rchk = '0;
        assign obi_load_rsp_o.r.err = '0;
        assign obi_load_rsp_o.r.rdata = hpdcache_rsp_i.rdata;
        assign obi_load_rsp_o.r.r_optional.ruser = '0;

      end else begin

        // In case we have a MMU and we want a compliance to OBI protocol, we need to delay response in case of HIT.

        obi_load_rsp_t obi_load_rsp_q, obi_load_rsp_d;
        logic resp_while_request;
        logic buffered_valid;
        logic killed_in_s1;

        assign obi_load_rsp_d.gnt = '0;  //unused
        assign obi_load_rsp_d.gntpar = '0;  //unused
        assign obi_load_rsp_d.rvalid = hpdcache_rsp_valid_i;
        assign obi_load_rsp_d.rvalidpar = !hpdcache_rsp_valid_i;
        assign obi_load_rsp_d.r.rid = hpdcache_rsp_i.tid;
        assign obi_load_rsp_d.r.r_optional.exokay = '0;
        assign obi_load_rsp_d.r.r_optional.rchk = '0;
        assign obi_load_rsp_d.r.err = '0;
        assign obi_load_rsp_d.r.rdata = hpdcache_rsp_i.rdata;
        assign obi_load_rsp_d.r.r_optional.ruser = '0;

        assign resp_while_request = (obi_load_req_i.a.aid == hpdcache_rsp_i.tid) && obi_load_req_i.req && obi_load_rsp_o.gnt ? hpdcache_rsp_valid_i : 1'b0;
        assign killed_in_s1 = (obi_load_req_i.a.aid == hpdcache_rsp_i.tid) ? load_req_i.kill_req : 1'b0; //maybe can be managed by need_resp = 0

        always @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin
            buffered_valid <= 1'b0;
            obi_load_rsp_q <= 1'b0;
          end else begin
            if (resp_while_request) begin
              obi_load_rsp_q <= obi_load_rsp_d;
              buffered_valid <= 1'b1;
            end
            if (buffered_valid) begin
              buffered_valid <= 1'b0;
            end
          end
        end

        assign obi_load_rsp_o.rvalid               = resp_while_request ? '0 : (buffered_valid ? 1'b1 : (killed_in_s1 ? 1'b0 : hpdcache_rsp_valid_i));
        assign obi_load_rsp_o.rvalidpar = !obi_load_rsp_o.rvalid;
        assign obi_load_rsp_o.r.rid                = resp_while_request ? '0 : (buffered_valid ? obi_load_rsp_q.r.rid               : obi_load_rsp_d.r.rid);
        assign obi_load_rsp_o.r.r_optional.exokay  = resp_while_request ? '0 : (buffered_valid ? obi_load_rsp_q.r.r_optional.exokay : obi_load_rsp_d.r.r_optional.exokay);
        assign obi_load_rsp_o.r.r_optional.rchk    = resp_while_request ? '0 : (buffered_valid ? obi_load_rsp_q.r.r_optional.rchk   : obi_load_rsp_d.r.r_optional.rchk);
        assign obi_load_rsp_o.r.err                = resp_while_request ? '0 : (buffered_valid ? obi_load_rsp_q.r.err               : obi_load_rsp_d.r.err);
        assign obi_load_rsp_o.r.rdata              = resp_while_request ? '0 : (buffered_valid ? obi_load_rsp_q.r.rdata             : obi_load_rsp_d.r.rdata);
        assign obi_load_rsp_o.r.r_optional.ruser   = resp_while_request ? '0 : (buffered_valid ? obi_load_rsp_q.r.r_optional.ruser  : obi_load_rsp_d.r.r_optional.ruser);

      end



      //  Assertions
      //  {{{
      //    pragma translate_off
      flush_on_load_port_assert :
      assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1) (cva6_dcache_flush_i == 1'b0))
      else $error("Flush unsupported on load adapters");
      //    pragma translate_on
      //  }}}
    end  //  }}}

         //  {{{

    else if (IsMmuPtwPort == 1'b1) begin : mmu_ptw_port_gen
      //  MMU request
      //  {{{
      assign hpdcache_req_is_uncacheable = !config_pkg::is_inside_cacheable_regions(
          CVA6Cfg,
          {
            {64 - CVA6Cfg.DCACHE_TAG_WIDTH{1'b0}}
            , obi_mmu_ptw_req_i.address_tag
            , {CVA6Cfg.DCACHE_INDEX_WIDTH{1'b0}}
          }
      );

      //    Request forwarding
      assign hpdcache_req_valid_o = obi_mmu_ptw_req_i.data_req;
      assign hpdcache_req.addr_offset = obi_mmu_ptw_req_i.address_index;
      assign hpdcache_req.wdata = '0;
      assign hpdcache_req.op = hpdcache_pkg::HPDCACHE_REQ_LOAD;
      assign hpdcache_req.be = obi_mmu_ptw_req_i.data_be;
      assign hpdcache_req.size = obi_mmu_ptw_req_i.data_size;
      assign hpdcache_req.sid = hpdcache_req_sid_i;
      assign hpdcache_req.tid = obi_mmu_ptw_req_i.data_id;
      assign hpdcache_req.need_rsp = 1'b1;
      assign hpdcache_req.phys_indexed = 1'b0;
      assign hpdcache_req.addr_tag = '0;  // unused on virtually indexed request
      assign hpdcache_req.pma.uncacheable = hpdcache_req_is_uncacheable;
      assign hpdcache_req.pma.io = 1'b0;
      assign hpdcache_req.pma.wr_policy_hint = hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO;

      assign hpdcache_req_abort_o = obi_mmu_ptw_req_i.kill_req;
      assign hpdcache_req_tag_o = obi_mmu_ptw_req_i.address_tag;

      assign hpdcache_req_pma_o.uncacheable = hpdcache_req_is_uncacheable;
      assign hpdcache_req_pma_o.io = 1'b0;
      assign hpdcache_req_pma_o.wr_policy_hint = hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO;

      //    Response forwarding
      assign obi_mmu_ptw_rsp_o.data_rvalid = hpdcache_rsp_valid_i;
      assign obi_mmu_ptw_rsp_o.data_rdata = hpdcache_rsp_i.rdata;
      assign obi_mmu_ptw_rsp_o.data_rid = hpdcache_rsp_i.tid;
      assign obi_mmu_ptw_rsp_o.data_gnt = hpdcache_req_ready_i;

      //  Assertions
      //  {{{
      //    pragma translate_off
      flush_on_load_port_assert :
      assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1) (cva6_dcache_flush_i == 1'b0))
      else $error("Flush unsupported on mmu adapters");
      //    pragma translate_on
      //  }}}
    end  //  }}}
else if (IsZcmtPort == 1'b1) begin : zcmt_port_gen
      //  ZCMT request
      //  {{{
      assign hpdcache_req_is_uncacheable = !config_pkg::is_inside_cacheable_regions(
          CVA6Cfg,
          {
            {64 - CVA6Cfg.DCACHE_TAG_WIDTH{1'b0}}
            , obi_zcmt_req_i.address_tag
            , {CVA6Cfg.DCACHE_INDEX_WIDTH{1'b0}}
          }
      );

      //    Request forwarding
      assign hpdcache_req_valid_o = obi_zcmt_req_i.data_req;
      assign hpdcache_req.addr_offset = obi_zcmt_req_i.address_index;
      assign hpdcache_req.wdata = '0;
      assign hpdcache_req.op = hpdcache_pkg::HPDCACHE_REQ_LOAD;
      assign hpdcache_req.be = obi_zcmt_req_i.data_be;
      assign hpdcache_req.size = obi_zcmt_req_i.data_size;
      assign hpdcache_req.sid = hpdcache_req_sid_i;
      assign hpdcache_req.tid = obi_zcmt_req_i.data_id;
      assign hpdcache_req.need_rsp = 1'b1;
      assign hpdcache_req.phys_indexed = 1'b0;
      assign hpdcache_req.addr_tag = '0;  // unused on virtually indexed request
      assign hpdcache_req.pma.uncacheable = hpdcache_req_is_uncacheable;
      assign hpdcache_req.pma.io = 1'b0;
      assign hpdcache_req.pma.wr_policy_hint = hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO;

      assign hpdcache_req_abort_o = obi_zcmt_req_i.kill_req;
      assign hpdcache_req_tag_o = obi_zcmt_req_i.address_tag;

      assign hpdcache_req_pma_o.uncacheable = hpdcache_req_is_uncacheable;
      assign hpdcache_req_pma_o.io = 1'b0;
      assign hpdcache_req_pma_o.wr_policy_hint = hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO;

      //    Response forwarding
      assign obi_zcmt_rsp_o.data_rvalid = hpdcache_rsp_valid_i;
      assign obi_zcmt_rsp_o.data_rdata = hpdcache_rsp_i.rdata;
      assign obi_zcmt_rsp_o.data_rid = hpdcache_rsp_i.tid;
      assign obi_zcmt_rsp_o.data_gnt = hpdcache_req_ready_i;

      //  Assertions
      //  {{{
      //    pragma translate_off
      flush_on_load_port_assert :
      assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1) (cva6_dcache_flush_i == 1'b0))
      else $error("Flush unsupported on Zcmt adapters");
      //    pragma translate_on
      //  }}}
    end  //  }}}

         //  {{{
    else begin : store_amo_gen
      //  STORE/AMO request
      logic                 [63:0] amo_addr;
      hpdcache_req_offset_t        amo_addr_offset;
      hpdcache_tag_t               amo_tag;
      logic amo_is_word, amo_is_word_hi;
      logic                           [63:0] amo_data;
      logic                           [ 7:0] amo_data_be;
      logic                           [ 1:0] amo_data_size;
      logic                           [ 1:0] store_data_size;

      hpdcache_pkg::hpdcache_req_op_t        amo_op;
      logic                           [31:0] amo_resp_word;
      logic                                  amo_pending_q;

      hpdcache_req_t                         hpdcache_req_amo;
      hpdcache_req_t                         hpdcache_req_store;
      hpdcache_req_t                         hpdcache_req_flush;

      flush_fsm_t flush_fsm_q, flush_fsm_d;

      logic forward_store, forward_amo, forward_flush;

      //  DCACHE flush request
      //  {{{
      always_ff @(posedge clk_i or negedge rst_ni) begin : flush_ff
        if (!rst_ni) begin
          flush_fsm_q <= FLUSH_IDLE;
        end else begin
          flush_fsm_q <= flush_fsm_d;
        end
      end

      always_comb begin : flush_comb
        forward_flush = 1'b0;
        cva6_dcache_flush_ack_o = 1'b0;

        flush_fsm_d = flush_fsm_q;

        case (flush_fsm_q)
          FLUSH_IDLE: begin
            if (cva6_dcache_flush_i) begin
              forward_flush = 1'b1;
              if (hpdcache_req_ready_i) begin
                flush_fsm_d = FLUSH_PEND;
              end
            end
          end
          FLUSH_PEND: begin
            if (hpdcache_rsp_valid_i) begin
              if (hpdcache_rsp_i.tid == '0) begin
                cva6_dcache_flush_ack_o = 1'b1;
                flush_fsm_d = FLUSH_IDLE;
              end
            end
          end
          default: begin
          end
        endcase
      end
      //  }}}

      if (CVA6Cfg.XLEN == 64) begin
        assign amo_data_size   = ariane_pkg::size_gen(obi_amo_req_i.a.be);
        assign store_data_size = ariane_pkg::size_gen(obi_store_req_i.a.be);
      end else begin
        assign amo_data_size   = ariane_pkg::size_gen_32(obi_amo_req_i.a.be);
        assign store_data_size = ariane_pkg::size_gen_32(obi_store_req_i.a.be);
      end

      //  AMO logic
      //  {{{
      always_comb begin : amo_op_comb
        amo_addr = obi_amo_req_i.a.addr;
        amo_addr_offset = amo_addr[0+:HPDcacheCfg.reqOffsetWidth];
        amo_tag = amo_addr[HPDcacheCfg.reqOffsetWidth+:HPDcacheCfg.tagWidth];
        unique case (obi_amo_req_i.a.a_optional.atop)
          obi_pkg::ATOPLR:  amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_LR;
          obi_pkg::ATOPSC:  amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_SC;
          obi_pkg::AMOSWAP: amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_SWAP;
          obi_pkg::AMOADD:  amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_ADD;
          obi_pkg::AMOAND:  amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_AND;
          obi_pkg::AMOOR:   amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_OR;
          obi_pkg::AMOXOR:  amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_XOR;
          obi_pkg::AMOMAX:  amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_MAX;
          obi_pkg::AMOMAXU: amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_MAXU;
          obi_pkg::AMOMIN:  amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_MIN;
          obi_pkg::AMOMINU: amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_MINU;
          default:          amo_op = hpdcache_pkg::HPDCACHE_REQ_LOAD;
        endcase
      end
      //  }}}

      //  Request forwarding
      //  {{{
      assign amo_is_word = (amo_data_size == 2'b10);
      assign amo_is_word_hi = obi_amo_req_i.a.addr[2];
      if (CVA6Cfg.XLEN == 64) begin : amo_data_64_gen
        assign amo_data = amo_is_word ? {2{obi_amo_req_i.a.wdata[0+:32]}} : obi_amo_req_i.a.wdata;
        assign amo_data_be = amo_is_word_hi ? 8'hf0 : amo_is_word ? 8'h0f : 8'hff;
      end else begin : amo_data_32_gen
        assign amo_data    = {32'b0, obi_amo_req_i.a.wdata};
        assign amo_data_be = 8'h0f;
      end

      assign hpdcache_req_amo = '{
              addr_offset: amo_addr_offset,
              wdata: amo_data,
              op: amo_op,
              be: amo_data_be,
              size: amo_data_size,
              sid: hpdcache_req_sid_i,
              tid: '1,
              need_rsp: 1'b1,
              phys_indexed: 1'b1,
              addr_tag: amo_tag,
              pma: '{
                  uncacheable:
                  !
                  obi_amo_req_i.a.a_optional.memtype[
                  1
                  ],  // memtype[1] = 1 is cacheable, memtype[1] = 0 is non cacheable
                  io: 1'b0,
                  wr_policy_hint: hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO
              }
          };

      assign hpdcache_req_store = '{
              addr_offset: obi_store_req_i.a.addr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0],
              wdata: obi_store_req_i.a.wdata,
              op: hpdcache_pkg::HPDCACHE_REQ_STORE,
              be: obi_store_req_i.a.be,
              size: store_data_size,
              sid: hpdcache_req_sid_i,
              tid: '0,
              need_rsp: 1'b0,
              phys_indexed: 1'b1,
              addr_tag:
              obi_store_req_i.a.addr[
              CVA6Cfg.DCACHE_TAG_WIDTH+CVA6Cfg.DCACHE_INDEX_WIDTH-1
              :
              CVA6Cfg.DCACHE_INDEX_WIDTH
              ],
              pma: '{
                  uncacheable:
                  !
                  obi_store_req_i.a.a_optional.memtype[
                  1
                  ],  // memtype[1] = 1 is cacheable, memtype[1] = 0 is non cacheable
                  io: 1'b0,
                  wr_policy_hint: hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO
              }
          };

      assign hpdcache_req_flush = '{
              addr_offset: '0,
              addr_tag: '0,
              wdata: '0,
              op:
              InvalidateOnFlush
              ?
              hpdcache_pkg::HPDCACHE_REQ_CMO_FLUSH_INVAL_ALL
              :
              hpdcache_pkg::HPDCACHE_REQ_CMO_FLUSH_ALL,
              be: '0,
              size: '0,
              sid: hpdcache_req_sid_i,
              tid: '0,
              need_rsp: 1'b1,
              phys_indexed: 1'b0,
              pma: '{
                  uncacheable: 1'b0,
                  io: 1'b0,
                  wr_policy_hint: hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO
              }
          };

      assign forward_store = obi_store_req_i.req;
      assign forward_amo = CVA6Cfg.RVA ? obi_amo_req_i.req : '0;

      assign hpdcache_req_valid_o = (forward_amo & ~amo_pending_q) | forward_store | forward_flush;

      assign hpdcache_req = forward_amo   ? hpdcache_req_amo :
                            forward_store ? hpdcache_req_store : hpdcache_req_flush;

      assign hpdcache_req_abort_o = 1'b0;  // unused on physically indexed requests
      assign hpdcache_req_tag_o = '0;  // unused on physically indexed requests
      assign hpdcache_req_pma_o.uncacheable = 1'b0;
      assign hpdcache_req_pma_o.io = 1'b0;
      assign hpdcache_req_pma_o.wr_policy_hint = hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO;
      //  }}}

      //  Response forwarding
      //  {{{
      if (CVA6Cfg.XLEN == 64) begin : amo_resp_64_gen
        assign amo_resp_word = amo_is_word_hi
                             ? hpdcache_rsp_i.rdata[0][32 +: 32]
                             : hpdcache_rsp_i.rdata[0][0  +: 32];
      end else begin : amo_resp_32_gen
        assign amo_resp_word = hpdcache_rsp_i.rdata[0];
      end

      logic obi_store_valid;
      logic obi_amo_valid;

      assign obi_store_valid = hpdcache_rsp_valid_i && (hpdcache_rsp_i.tid != '1);
      assign obi_amo_valid = hpdcache_rsp_valid_i && (hpdcache_rsp_i.tid == '1);

      //OBI
      assign obi_store_rsp_o.gnt = hpdcache_req_ready_i & obi_store_req_i.req;
      assign obi_store_rsp_o.gntpar = !obi_store_rsp_o.gnt;
      assign obi_store_rsp_o.rvalid = obi_store_valid;
      assign obi_store_rsp_o.rvalidpar = !obi_store_valid;
      assign obi_store_rsp_o.r.rid = '0;
      assign obi_store_rsp_o.r.r_optional.exokay = '0;
      assign obi_store_rsp_o.r.r_optional.rchk = '0;
      assign obi_store_rsp_o.r.err = '0;
      assign obi_store_rsp_o.r.rdata = '0;
      assign obi_store_rsp_o.r.r_optional.ruser = '0;

      assign obi_amo_rsp_o.gnt = hpdcache_req_ready_i & forward_amo;
      assign obi_amo_rsp_o.gntpar = !obi_amo_rsp_o.gnt;
      assign obi_amo_rsp_o.rvalid = obi_amo_valid;
      assign obi_amo_rsp_o.rvalidpar = !obi_amo_valid;
      assign obi_amo_rsp_o.r.rid = '0;
      assign obi_amo_rsp_o.r.r_optional.exokay = '0;
      assign obi_amo_rsp_o.r.r_optional.rchk = '0;
      assign obi_amo_rsp_o.r.err = '0;
      assign obi_amo_rsp_o.r.rdata = amo_is_word ? {{32{amo_resp_word[31]}}, amo_resp_word}
                                                        : hpdcache_rsp_i.rdata[0];
      assign obi_amo_rsp_o.r.r_optional.ruser = '0;
      //  }}}

      always_ff @(posedge clk_i or negedge rst_ni) begin : amo_pending_ff
        if (!rst_ni) begin
          amo_pending_q <= 1'b0;
        end else begin
          amo_pending_q <=
              ( obi_amo_req_i.req  & hpdcache_req_ready_i & ~amo_pending_q) |
              (~obi_amo_valid & amo_pending_q);
        end
      end

      //  Assertions
      //  {{{
      //    pragma translate_off
      forward_one_request_assert :
      assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1) ($onehot0(
          {forward_store, forward_amo, forward_flush}
      )))
      else $error("Only one request shall be forwarded");
      //    pragma translate_on
      //  }}}
    end
    //  }}}
  endgenerate
  //  }}}

  assign hpdcache_req_o = hpdcache_req;
  //  }}}
endmodule
