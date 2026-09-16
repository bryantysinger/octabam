// Stock contracts the Repitch patch depends on: TSTR's UI mapping and the
// rate-selection basic block. This is not full sample playback.
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>
#include "machine.h"
#include "mc68k/Musashi/m68k.h"
#include "mc68k/cpuState.h"

int main(int argc, char** argv)
{
    const bool patched = argc > 1 && std::string(argv[1]) == "--patched";
    const std::string path = patched
        ? (argc > 2 ? argv[2] : "out/mainos_bus.bin")
        : (argc > 1 ? argv[1] : "out/raw/section_3_MAIN_OS.bin");
    std::ifstream input(path, std::ios::binary);
    if(!input) {
        std::printf("SKIP: %s is not present (run `make os`)\n", path.c_str());
        return 0;
    }
    std::vector<uint8_t> image((std::istreambuf_iterator<char>(input)), {});
    if(image.size() != 1112560) { std::fprintf(stderr, "Expected stock 1.40C MAIN OS\n"); return 2; }
    int failures = 0;
    constexpr uint32_t imageBase = 0x40000400;
    const auto read32 = [&](const uint32_t address) {
        const auto i = address - imageBase;
        return (uint32_t(image[i]) << 24) | (uint32_t(image[i + 1]) << 16) |
               (uint32_t(image[i + 2]) << 8) | uint32_t(image[i + 3]);
    };
    const auto cstr = [&](const uint32_t address) {
        std::string out;
        for(auto i = address - imageBase; i < image.size() && image[i]; ++i)
            out.push_back(char(image[i]));
        return out;
    };
    const auto check = [&](const char* what, const bool ok) {
        failures += !ok;
        std::printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
    };

    if(patched) {
        std::printf("Repitch patched-image contracts:\n");
        const auto formatter = read32(0x400d310e);
        if(read32(0x400d30de) != 5 || formatter == 0x4003b6a4) {
            std::printf("SKIP: %s is not a REPITCH remix image\n", path.c_str());
            return 0;
        }
        check("STATIC/FLEX/PICKUP counts grow to 5/5/4",
              read32(0x400d30de) == 5 && read32(0x400d3270) == 5 &&
              read32(0x400d36f6) == 1 && read32(0x400d3726) == 4);
        check("all TSTR descriptors point to one new formatter",
              formatter != 0x4003b6a4 && formatter == read32(0x400d32a0) &&
              formatter == read32(0x400d3756));

        bool labelsOk = true;
        const char* labels[] = {"OFF", "AUTO", "NORM", "BEAT", "REPITCH"};
        for(unsigned value = 0; value < 5; ++value) {
            ot::Machine machine(image);
            auto* cpu = machine.getCpuState();
            constexpr uint32_t sp = 0x47003000, buf = 0x47004000, returned = 0x47005000;
            machine.write32(sp, returned);
            machine.write32(sp + 4, buf);
            machine.write32(sp + 8, value);
            machine.write32(buf, 0);
            m68k_set_reg(cpu, M68K_REG_SP, sp);
            m68k_set_reg(cpu, M68K_REG_PC, formatter);
            unsigned steps = 0;
            while(machine.pc() != returned && steps++ < 2000)
                if(!machine.step()) break;
            std::string got;
            for(unsigned i = 0; i < 16 && machine.read8(buf + i); ++i)
                got.push_back(char(machine.read8(buf + i)));
            labelsOk &= machine.pc() == returned && got == labels[value];
            if(got != labels[value])
                std::printf("  [FAIL] TSTR %u printed '%s', expected '%s'\n",
                            value, got.c_str(), labels[value]);
        }
        check("formatter prints OFF, AUTO, NORM, BEAT, REPITCH", labelsOk);

        bool gatesOk = true;
        for(unsigned value = 0; value < 5; ++value) {
            for(const auto site : {0x40007edeu, 0x40008210u}) {
                ot::Machine machine(image);
                auto* cpu = machine.getCpuState();
                constexpr uint32_t voice = 0x47006000, sp = 0x47007000;
                machine.write8(voice + 24, value);
                m68k_set_reg(cpu, M68K_REG_A2, voice);
                m68k_set_reg(cpu, M68K_REG_A6, 0x47008000);
                m68k_set_reg(cpu, M68K_REG_A0, 0x1234);
                m68k_set_reg(cpu, M68K_REG_D0, 0x89abcdef);
                m68k_set_reg(cpu, M68K_REG_SP, sp);
                m68k_set_reg(cpu, M68K_REG_PC, site);
                const auto dry = site == 0x40007edeu ? 0x40007ee8u : 0x4000822au;
                const auto wet = site == 0x40007edeu ? 0x40007f02u : 0x4000821eu;
                const auto want = (value == 0 || value == 4) ? dry : wet;
                unsigned steps = 0;
                while(machine.pc() != want && steps++ < 40)
                    if(!machine.step()) break;
                gatesOk &= machine.pc() == want &&
                           m68k_get_reg(cpu, M68K_REG_D0) == 0x89abcdef &&
                           m68k_get_reg(cpu, M68K_REG_SP) == sp;
            }
        }
        check("OFF and REPITCH take both dry gates; AUTO/NORM/BEAT stay granular", gatesOk);

        bool ratioOk = true;
        const auto rateHook = read32(0x40004102); // target of jmp abs.l at 0x40004100
        constexpr uint32_t lane = 0x47009000, state = 0x80004898;
        constexpr uint32_t voice = 0x800049d8, settings = 0x4700a000, sp = 0x4700b000;
        constexpr uint32_t sourceTempo = 2880, increment = 0x04000000;
        for(const unsigned projectTempo : {1440u, 2160u, 2880u, 4320u, 5760u})
        for(const unsigned tstr : {0u, 1u, 2u, 3u, 4u}) {
            ot::Machine machine(image);
            auto* cpu = machine.getCpuState();
            machine.write8(lane + 28, tstr);
            machine.write32(0x800062a4, state);
            machine.write32(voice + 8, settings);
            machine.write32(settings + 0x114, sourceTempo);
            machine.write32(0x8000181c, projectTempo);
            m68k_set_reg(cpu, M68K_REG_A3, state);
            m68k_set_reg(cpu, M68K_REG_A6, lane);
            m68k_set_reg(cpu, M68K_REG_D0, increment);
            m68k_set_reg(cpu, M68K_REG_SP, sp);
            m68k_set_reg(cpu, M68K_REG_PC, rateHook + 4); // after displaced movclr/asr
            unsigned steps = 0;
            while(machine.pc() != 0x40004108 && steps++ < 120)
                if(!machine.step()) break;
            const uint32_t want = tstr == 4
                ? uint32_t((uint64_t(increment) * projectTempo) / sourceTempo)
                : increment;
            const auto got = machine.read32(state + 36);
            ratioOk &= machine.pc() == 0x40004108 && got == want;
            if(got != want)
                std::printf("  [FAIL] project=%u TSTR=%u increment=%#x want=%#x\n",
                            projectTempo, tstr, got, want);
        }
        check("only REPITCH scales the shared increment by project/source BPM", ratioOk);
        std::printf("%d failure(s); synthetic patched-image contracts\n", failures);
        return failures ? 1 : 0;
    }

    std::printf("Repitch stock contracts:\n");
    check("STATIC and FLEX TSTR each expose four values",
          read32(0x400d30de) == 4 && read32(0x400d3270) == 4);
    check("PICKUP TSTR exposes values 1..3",
          read32(0x400d36f6) == 1 && read32(0x400d3726) == 3);
    check("all three TSTR slots use formatter 0x4003b6a4",
          read32(0x400d310e) == 0x4003b6a4 &&
          read32(0x400d32a0) == 0x4003b6a4 &&
          read32(0x400d3756) == 0x4003b6a4);
    check("raw TSTR mapping is OFF, AUTO, NORM, BEAT",
          cstr(read32(0x400a7e2e)) == "OFF" &&
          cstr(read32(0x400a7e32)) == "AUTO" &&
          cstr(read32(0x400a7e36)) == "NORM" &&
          cstr(read32(0x400a7e3a)) == "BEAT");

    constexpr uint32_t frame = 0x47000000, lane = 0x47001000;
    constexpr uint32_t settings = 0x47002000, voice = 0x800049d8;
    int rateFailures = 0;
    // PTCH 0 maps through stock's table; neutral index is 64 (0x4000 >> 8).
    for(const unsigned tempo : {1440u, 2160u, 2880u, 4320u, 5760u})
    for(const unsigned rateMode : {0u, 1u})
    for(const unsigned tstr : {0u, 1u, 2u, 3u, 4u})
    {
        ot::Machine machine(image);
        auto* cpu = machine.getCpuState();
        m68k_set_reg(cpu, M68K_REG_A6, frame);
        m68k_set_reg(cpu, M68K_REG_A2, voice);
        m68k_set_reg(cpu, M68K_REG_D2, tempo);
        machine.write32(frame - 72, lane);
        machine.write32(frame - 76, settings);
        machine.write32(frame - 80, tempo);
        machine.write16(lane, 0x4000); // neutral PTCH table index
        machine.write8(lane + 27, rateMode);
        machine.write8(voice + 24, tstr);
        machine.write32(settings + 0x114, 2880);
        machine.write32(settings + 0x118, 0x12345678); // identifies the source selected
        m68k_set_reg(cpu, M68K_REG_PC, 0x400081c2);
        unsigned steps = 0;
        while(machine.pc() != 0x4000822a && steps++ < 80)
            if(!machine.step()) break;
        const auto actual = m68k_get_reg(cpu, M68K_REG_A4);
        const auto grain = m68k_get_reg(cpu, M68K_REG_A3) & 0xffff;
        const auto reciprocal = m68k_get_reg(cpu, M68K_REG_A5);
        const auto wantGrain = tstr ? 2880u : tempo;
        const auto wantReciprocal = tstr ? 0x12345678u : 0x80000000u / tempo;
        const bool ok = machine.pc() == 0x4000822a && actual == tempo &&
                        grain == wantGrain && reciprocal == wantReciprocal;
        failures += !ok;
        rateFailures += !ok;
        if(!ok)
            std::printf("  [FAIL] tempo24=%u rate-mode=%u TSTR=%u playback=%u grain=%u reciprocal=%#x\n",
                        tempo, rateMode, tstr, actual, grain, reciprocal);
    }
    check("stock rate block treats OFF as dry and every nonzero TSTR value as granular",
          rateFailures == 0);
    std::printf("%d failure(s); synthetic stock contracts only\n", failures);
    return failures ? 1 : 0;
}
