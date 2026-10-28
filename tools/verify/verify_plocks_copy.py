#!/usr/bin/env python3
"""Execute PLOCKS' snapshot mirror through EVENTS, including a negative control.

Only native memcpy and nv_touch bodies are substituted; the assembled client,
dispatcher, address validation and complete side-data copies execute. The
full-firmware panel/save gate separately exercises those native bodies.
"""
from pathlib import Path
import runpy
import struct
import subprocess
import tempfile

import verify_system_events as fixture
from unicorn import Uc, UC_ARCH_M68K, UC_MODE_BIG_ENDIAN, UC_HOOK_CODE
from unicorn.m68k_const import UC_CPU_M68K_CFV4E

ROOT = fixture.ROOT


class Mirror(fixture.Fixture):
    def __init__(self, work, disabled=False):
        source = (ROOT / 'modules/plocks-p2/p2locks.s').read_text()
        if disabled:
            old = 'beq.w   mc_locks'
            assert source.count(old) == 1
            source = source.replace(old, 'beq.w   mc_stock')
        (work / 'plocks.s').write_text(source)
        # Both units use generated remix.inc, with independent contracts.
        declarations = [runpy.run_path(str(ROOT / 'modules' / name / 'manifest.py'))
                        for name in ('plocks-p2', 'events')]
        from remix import registry
        include = declarations[0]['ids_inc']({'PLOCKS P2'}, registry.remix('events-clients'))
        include += declarations[1]['event_inc']({'PLOCKS P2'})
        (work / 'remix.inc').write_text(include)
        objects = []
        for name, path in (('plocks', work / 'plocks.s'),
                           ('events', ROOT / 'modules/events/edit.s')):
            obj = work / (name + '.o')
            subprocess.run(['m68k-elf-as', '-mcpu=54455', '-I', str(work), '-I', str(ROOT),
                            '-o', str(obj), str(path)], check=True, capture_output=True)
            objects.append(str(obj))
        elf, binary = work / 'probe.elf', work / 'probe.bin'
        subprocess.run(['m68k-elf-ld', '-Ttext=0x48000000', '--defsym=store_refuse=0x47003000',
                        '-o', str(elf), *objects], check=True, capture_output=True)
        subprocess.run(['m68k-elf-objcopy', '-O', 'binary', str(elf), str(binary)], check=True)
        nm = subprocess.check_output(['m68k-elf-nm', str(elf)], text=True)
        self.sym = {f[2]: int(f[0], 16) for line in nm.splitlines() if len(f := line.split()) == 3}
        self.uc = u = Uc(UC_ARCH_M68K, UC_MODE_BIG_ENDIAN)
        u.ctl_set_cpu_model(UC_CPU_M68K_CFV4E)
        for address, size in ((0x10000000, 0x100000), (0x40000000, 0x1000000),
                              (0x460b0000, 0x30000), (0x46c70000, 0x20000),
                              (0x47000000, 0x10000), (fixture.BASE, 0x200000),
                              (0x80000000, 0x10000)):
            u.mem_map(address, size)
        u.mem_write(fixture.BASE, binary.read_bytes())
        u.mem_write(fixture.DONE - 16, bytes.fromhex('40c7'))
        self.callbacks = {}
        self.nv_calls = 0
        u.hook_add(UC_HOOK_CODE, self.hook)

    def hook(self, u, pc, size, data):
        if pc == self.sym['nv_touch']:
            self.nv_calls += 1
            self.ret()
            return
        super().hook(u, pc, size, data)

    def copy(self, src, dst, side_src, side_dst, *, bank=False, size=2048,
             initialized=True, mirror=True):
        u, s = self.uc, self.sym
        regions = [(s['STORE'], s['STORE_LEN']), (s['P2BUF0'], 6144), (s['P2BUF1'], 6144)]
        for address, length in regions:
            u.mem_write(address, b'\xff' * length)
        u.mem_write(s['INITED'], struct.pack('>I', s['MAGIC'] if initialized else 0))
        payload = bytes(255 if i % 11 == 0 else i % 128 for i in range(768))
        u.mem_write(side_src, payload)
        expected = [bytearray(u.mem_read(address, length)) for address, length in regions]
        if mirror and initialized:
            for (address, length), data in zip(regions, expected):
                if address <= side_dst < address + length:
                    data[side_dst - address:side_dst - address + 768] = payload
        native = bytes(i % 256 for i in range(size))
        u.mem_write(src, native)
        u.mem_write(dst, bytes(size))
        self.nv_calls = 0
        self.call('ed_copy', args=(dst, src, size))
        self.preserved({0: dst}, fixture.STACK + 4)
        assert self.native_count == 1 and bytes(u.mem_read(dst, size)) == native
        assert self.nv_calls == int(mirror and initialized and bank)
        assert all(bytes(u.mem_read(address, length)) == data
                   for (address, length), data in zip(regions, expected)), 'side-data snapshot differs'


def main():
    cases = 0
    with tempfile.TemporaryDirectory(prefix='octabam-plocks-copy-') as td:
        work = Path(td)
        f = Mirror(work)
        s = f.sym
        for bank in (0, 7, 15):
            for pattern in (0, 15):
                for track in (0, 7):
                    native = s['BLOB'] + bank*s['BANK_STRIDE'] + pattern*s['PTN_STRIDE'] + track*s['TRK_STRIDE'] + 0x59
                    side = s['STORE'] + ((bank*16 + pattern)*8 + track)*768
                    for buf, side_buf in (('UNDO', 'P2BUF1'), ('CLIP', 'P2BUF0')):
                        bn, bs = s[buf] + 0x28, s[side_buf]
                        f.copy(native, bn, side, bs)
                        f.copy(bn, native, bs, side, bank=True)
                        cases += 2
        native, side = s['BLOB'] + 0x59, s['STORE']
        bn, bs = s['UNDO'] + 0x28, s['P2BUF1']
        for offset in (-1, 1, 32, s['TRK_STRIDE']*8):
            f.copy(native + offset, bn, side, bs, mirror=False)
            f.copy(bn, native + offset, bs, side, mirror=False)
            cases += 2
        for address in (0x10000059, s['BLOB'] - 1, s['BLOB'] + 16*s['BANK_STRIDE'] + 0x59):
            f.copy(bn, address, bs, side, mirror=False)
            cases += 1
        f.copy(bn, native, bs, side, initialized=False)
        f.copy(bn, native, bs, side, size=2047, mirror=False)
        cases += 2
        # Same candidate, one branch disabled: the snapshot test must fail.
        broken = Mirror(work, disabled=True)
        try:
            broken.copy(native, bn, side, bs)
        except AssertionError as error:
            assert str(error) == 'side-data snapshot differs', error
        else:
            raise AssertionError('negative control did not detect the missing snapshot mirror')
    print(f'[ok] {cases} PLOCKS snapshot/restore and rejection cases; current-source negative control failed as expected')


if __name__ == '__main__':
    main()
