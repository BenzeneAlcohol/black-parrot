#
#   trace_gen.py
#

import numpy as np

class TraceGen:

  # constructor
  def __init__(self, ptag_width_p, vaddr_width_p, opcode_width_p, data_width_p):
    self.ptag_width_p = ptag_width_p
    self.vaddr_width_p = vaddr_width_p
    self.opcode_width_p = opcode_width_p
    # TODO: Update formatting operators to use data width
    self.data_width_p = data_width_p
    self.packet_len = ptag_width_p + vaddr_width_p + opcode_width_p + data_width_p + 1 # A bit is added to denote cached/uncached accesses

  # print header
  def print_header(self):
    header = "// generated by trace_gen.py \n"
    header += "// packet_len = " + str(self.packet_len) + "\n" 
    return header

  # send load
  # signed: sign extend or not
  # size: load size in bytes
  # vaddr: dcache pkt page offset
  def send_load(self, signed, size, vaddr, ptag, uncached):
    packet = "0001_"
    
    if(uncached):
      packet += "1_"
    else:
      packet += "0_"

    packet += format(ptag, "0"+str(self.ptag_width_p)+"b") + "_"

    if (size == 8):
      packet += "000011_"
    else:
      if (signed):
        if (size == 1):
          packet+= "000000_"
        elif (size == 2):
          packet += "000001_"
        elif (size == 4):
          packet += "000010_"
        else:
          raise ValueError("unexpected size for signed load.")
      else:
        if (size == 1):
          packet += "000100_"
        elif (size == 2):
          packet += "000101_"
        elif (size == 4):
          packet += "000110_"
        else:
          raise ValueError("unexpected size for unsigned load.")

    packet += format(vaddr, "0"+str(self.vaddr_width_p)+"b") + "_"
    packet += format(0, "066b") + "\n" 
    return packet

  # send store
  # signed: sign extend or not
  # size: store size in bytes
  # vaddr: dcache pkt page offset
  def send_store(self, size, vaddr, ptag, uncached, data):
    packet = "0001_"

    if(uncached):
      packet += "1_"
    else:
      packet += "0_"

    packet += format(ptag, "0"+str(self.ptag_width_p)+"b") + "_"
    
    if (size == 1):
      packet += "001000_"
    elif (size == 2):
      packet += "001001_"
    elif (size == 4):
      packet += "001010_"
    elif (size == 8):
      packet += "001011_"
    else:
      raise ValueError("unexpected size for store.")
    
    packet += format(vaddr, "0" + str(self.vaddr_width_p) + "b") + "_"
    packet += format(data, "066b") + "\n"
    return packet

  # receive data
  # data: expected data
  def recv_data(self, data):
    packet = "0010_"
    bin_data = np.binary_repr(data, 64)
    packet += "0" + "0"*(self.ptag_width_p) + "_" + "0"*(self.opcode_width_p) + "_" + "0"*(self.vaddr_width_p) + "_" + "00" + bin_data + "\n"
    return packet

  # wait for a number of cycles
  # num_cycles: number of cycles to wait.
  def wait(self, num_cycles):
    command = "0110_" + format(num_cycles, "0" + str(self.packet_len) + "b") + "\n"
    command += "0101_" + (self.packet_len)*"0" + "\n"
    return command

  # finish trace
  def test_finish(self):
    command = "// FINISH \n"
    command += self.wait(8)
    command += "0100_" + (self.packet_len)*"0" + "\n"
    return command

  def test_done(self):
    command = "// DONE \n"
    command += self.wait(8)
    command += "0011_" + (self.packet_len)*"0" + "\n"
    return command

  # wait for a single cycle
  def nop(self):
    return "0000_" + "0"*(self.packet_len) + "\n"
  
  # print comments in the trace file
  def print_comment(self, comment):
    return "// " + comment + "\n"
