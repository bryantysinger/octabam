"""Firmware-free regression for destructive Unicorn M68K host SR reads."""
import importlib.util
from pathlib import Path
import unittest

HAS_UNICORN = importlib.util.find_spec('unicorn') is not None
if HAS_UNICORN:
    import unicorn as un
    from unicorn import m68k_const as mc
    spec = importlib.util.spec_from_file_location('midi_machine', Path(__file__).resolve().parents[1] / 'midi_machine.py')
    midi = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(midi)


@unittest.skipUnless(HAS_UNICORN, 'existing emu extra not installed')
class StatusTests(unittest.TestCase):
    BASE, PROBE = 0x1000, 0x1800
    # BEQ equal; MOVEA #0x2222,A1; BRA capture; equal: MOVEA #0x1111,A1;
    # capture: MOVE.W SR,D7. All instructions after BEQ preserve condition codes.
    CONTINUE = bytes.fromhex('6700000c 227c00002222 60000008 227c00001111 40c7')

    def machine(self, model, opcode, ccr=0, d0=0, d1=0):
        u = un.Uc(un.UC_ARCH_M68K, un.UC_MODE_BIG_ENDIAN)
        u.ctl_set_cpu_model(model)
        u.mem_map(self.BASE, 0x2000)
        u.mem_write(self.BASE, opcode + self.CONTINUE)
        u.mem_write(self.PROBE, bytes.fromhex('40c7'))
        u.reg_write(mc.UC_M68K_REG_SR, 0x2700 | ccr)
        u.reg_write(mc.UC_M68K_REG_D0, d0)
        u.reg_write(mc.UC_M68K_REG_D1, d1)
        u.reg_write(mc.UC_M68K_REG_D7, 0xabcdef01)
        u.reg_write(mc.UC_M68K_REG_A7, 0x2800)
        u.emu_start(self.BASE, self.BASE + len(opcode), count=1)
        return u

    def resume(self, u, opcode):
        end = self.BASE + len(opcode) + len(self.CONTINUE)
        u.emu_start(self.BASE + len(opcode), end, count=10)
        return u.reg_read(mc.UC_M68K_REG_A1), u.reg_read(mc.UC_M68K_REG_D7) & 0xffff

    def test_capture_preserves_context_memory_flags_and_resumed_branch(self):
        # Each expected CCR comes from the instruction's documented operation.
        cases = [('7000', 0, 0, 4, True),       # MOVEQ zero; preserve X
                 ('70ff', 0, 0, 8, True),       # MOVEQ negative
                 ('4280', 0xffffffff, 0, 4, True),  # CLR
                 ('b081', 7, 7, 4, True),       # CMP equal; preserve X
                 ('b081', 0, 1, 9, True),       # CMP borrow
                 ('d081', 0xffffffff, 1, 0x15, False),  # ADD carry/zero
                 ('d081', 0x7fffffff, 1, 0xa, False),   # ADD overflow
                 ('9081', 0, 1, 0x19, False),    # SUB borrow
                 ('2f00', 0, 0, 4, True),       # MOVE zero to stack
                 ('207c76543210', 0, 0, None, True)]  # MOVEA preserves CCR
        for model in (mc.UC_CPU_M68K_CFV4E, mc.UC_CPU_M68K_M68000):
            for opcode, d0, d1, flags, keep_x in cases:
                code = bytes.fromhex(opcode)
                for ccr in range(32):
                    with self.subTest(model=model, opcode=opcode, ccr=ccr):
                        expected = 0x2700 | (ccr if flags is None else flags | (ccr & 16 if keep_x else 0))
                        u = self.machine(model, code, ccr, d0, d1)
                        before = bytes(u.context_save())
                        memory = bytes(u.mem_read(self.BASE, 0x2000))
                        self.assertEqual(midi.read_sr(u, self.PROBE), expected)
                        self.assertEqual(midi.read_sr(u, self.PROBE), expected)
                        self.assertEqual(bytes(u.context_save()), before)
                        self.assertEqual(bytes(u.mem_read(self.BASE, 0x2000)), memory)
                        self.assertEqual(self.resume(u, code), (0x1111 if expected & 4 else 0x2222, expected))

    def test_capture_works_with_fixed_or_affected_host_readback(self):
        code = bytes.fromhex('7000')  # MOVEQ #0,D0 must set Z
        for model in (mc.UC_CPU_M68K_CFV4E, mc.UC_CPU_M68K_M68000):
            good = self.machine(model, code)
            self.assertEqual(midi.read_sr(good, self.PROBE), 0x2704)
            self.assertEqual(self.resume(good, code), (0x1111, 0x2704))
            bad = self.machine(model, code)
            host = bad.reg_read(mc.UC_M68K_REG_SR)
            # Accept an upstream repair, including a patched same-version
            # wheel. The independent audit retains the observed defective
            # result; correctness above never uses host SR as its oracle.
            self.assertIn((host, *self.resume(bad, code)),
                          ((0x2704, 0x1111, 0x2704), (0x2700, 0x2222, 0x2700)))

    def test_interrupted_capture_restores_the_original_context(self):
        u = self.machine(mc.UC_CPU_M68K_CFV4E, bytes.fromhex('7000'))
        before = bytes(u.context_save())
        hook = u.hook_add(un.UC_HOOK_CODE, lambda cpu, pc, size, _: cpu.emu_stop() if pc == self.PROBE else None)
        with self.assertRaisesRegex(RuntimeError, 'did not complete'):
            midi.read_sr(u, self.PROBE)
        self.assertEqual(bytes(u.context_save()), before)
        u.hook_del(hook)
        self.assertEqual(self.resume(u, bytes.fromhex('7000')), (0x1111, 0x2704))

    def test_wrong_probe_is_rejected_without_running_it(self):
        u = self.machine(mc.UC_CPU_M68K_CFV4E, bytes.fromhex('7000'))
        before = bytes(u.context_save())
        u.mem_write(self.PROBE, bytes.fromhex('4e71'))
        with self.assertRaisesRegex(ValueError, 'MOVE.W SR,D7'):
            midi.read_sr(u, self.PROBE)
        self.assertEqual(bytes(u.context_save()), before)


if __name__ == '__main__':
    unittest.main()
