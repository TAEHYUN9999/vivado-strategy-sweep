# vivado-strategy-sweep

명령어 하나로 **Vivado implementation strategy를 일괄(sweep) 실행**하고, 타이밍을
비교한 뒤 가장 좋은 결과물을 패키징하는 도구입니다.

합성(synthesis)은 **한 번만** 수행하고, 그 결과를 공유하는 여러 implementation
run(`impl_<strategy>`)을 strategy별로 따로 생성해 비교 가능하게 만듭니다.
각 strategy마다 다음을 수집합니다.

- **타이밍**: WNS / TNS / WHS / THS / TPWS 와 PASS/FAIL 판정
- **리소스**: CLB LUTs, CLB Registers, Block RAM, DSPs
- **산출물**: `.bit` 비트스트림 + 라우팅 후 타이밍/리소스 리포트

마지막으로 각 run(기본 `--xsa all`)에 대해 **`.xsa`** 하드웨어 핸드오프(비트스트림
포함)를 생성하고, 타이밍이 가장 좋은 run을 best로 표시합니다 — Vitis에서 바로
사용 가능합니다.

두 가지 방식으로 쓸 수 있습니다.

1. **순수 셸** — `./scripts/run.sh ...` (Claude 불필요)
2. **Claude Code 슬래시 커맨드** — `/vivado-build ...` (스크립트를 실행한 뒤
   결과를 읽어 순위표와 분석 리포트를 자동 작성)

**Vivado 2023.1** / **Ubuntu 22.04** 에서 테스트했습니다.

---

## 빠른 시작 (셸)

```bash
# 아무것도 실행하지 않고 프로젝트 + strategy 목록만 검증 (약 1분):
./scripts/run.sh --xpr /경로/프로젝트.xpr --dry-run

# 풀 sweep (오래 걸림: 합성 1회 + strategy 개수만큼 implementation, 순차):
./scripts/run.sh --xpr /경로/프로젝트.xpr

# 단일 전략만 (이름 하나만 지정 → 합성 1회 + impl 1회, 훨씬 빠름):
./scripts/run.sh --xpr /경로/프로젝트.xpr --strategies "Performance_ExplorePostRoutePhysOpt"

# 여러 strategy/jobs 지정:
./scripts/run.sh --xpr /경로/프로젝트.xpr \
    --strategies "Performance_Explore,Performance_ExtraTimingOpt" --jobs 8
```

> 전략들은 **병렬이 아니라 순차**로 돕니다(하나 완료 후 다음). `--jobs N` 은 전략을
> N개 동시 실행하는 게 아니라 **한 impl run 내부에서 쓰는 코어 수**입니다.

결과는 **프로젝트(.xpr) 폴더 아래** `vivado_sweep_<타임스탬프>/` 에 저장됩니다
(`--outdir` 로 변경 가능). Vivado 프로젝트 폴더 내부에 한 폴더로 모이며,
프로젝트의 기존 소스/run 은 건드리지 않습니다.

```
vivado_sweep_<ts>/
├── summary.csv                       # 전략별 WNS/TNS/util 비교표 (13번째 열 run_dir = 실제 run 경로)
├── vivado.log / vivado_sweep.log     # Vivado / 스윕 전체 로그
└── Performance_<strategy>/           # 전략마다 하나
    ├── Performance_<strategy>.bit        # 비트스트림
    ├── Performance_<strategy>.ltx        # ILA 디버그 프로브
    ├── Performance_<strategy>.xsa        # 하드웨어 핸드오프 (--xsa all|best 시)
    ├── *_timing_summary.rpt / *_utilization.rpt
    ├── vitis/                            # --vitis-src 줬을 때: Vitis 워크스페이스
    └── troubleshoot/                     # 그 전략이 타이밍 실패(WNS<0||WHS<0)했을 때만
```

> 라우팅된 DCP 등 무거운 **원본 run** 은 sweep 폴더가 아니라 Vivado 프로젝트의
> `<project>.runs/impl_<strategy>/` 에 있습니다 (위 `summary.csv` 의 `run_dir` 열).

### 옵션

| 옵션 | 기본값 | 설명 |
|--------|---------|------|
| `--xpr PATH` | `$VB_XPR` | Vivado 프로젝트 (필수) |
| `--strategies "a,b,c"` | `scripts/strategies.txt` | sweep할 strategy 목록 (이름 하나만 주면 단일 전략) |
| `--jobs N` | `min(8, nproc)` | `launch_runs` 의 `-jobs` 값 (한 impl run 내부 코어 수) |
| `--outdir DIR` | `<프로젝트폴더>/vivado_sweep_<ts>` | 출력 디렉터리 (.xpr 폴더 기준) |
| `--synth-strategy NAME` | (변경 안 함) | `synth_1` strategy 덮어쓰기 |
| `--reuse-synth` | off | `synth_1` 이 100%면 재사용 (기본은 매 sweep마다 `reset_run` 후 **재합성**) |
| `--xsa best\|all\|none` | `all` | 어떤 run에 `.xsa`를 만들지 |
| `--vitis-src DIR\|auto` | `auto` | **timing-PASS** strategy의 `.xsa`로 Vitis 플랫폼+앱 워크스페이스 빌드 (JTAG 굽기용). `auto`=프로젝트 디렉터리에서 펌웨어 소스 자동탐지 |
| `--no-prep-ip` | off | IP 준비 단계(Refresh IP Catalog + Generate Output Products) 건너뛰기. 기본은 prep 켜짐. |
| `--no-vitis` | off | Vitis 플랫폼/앱/.elf/download.bit 빌드 건너뛰기. 기본은 Vitis 켜짐(`auto`). |
| `--vitis PATH` | 자동 탐지 | `xsct` 바이너리 경로 |
| `--no-troubleshoot` | off | 타이밍 실패 분석 단계 건너뛰기 |
| `--ts-max-paths N` | `10` | 위반 strategy당 분석할 worst path 수 |
| `--ts-logic-pct P` | `50` | `logic% >= P` 이면 logic-bound로 분류 |
| `--dry-run` | off | 검증 + 계획만 출력, 실행 안 함 |
| `--vivado PATH` | 자동 탐지 | `vivado` 바이너리 경로 |

기본 strategy 목록은 [`scripts/strategies.txt`](scripts/strategies.txt) 에서
수정합니다. 잘못된 strategy 이름은 (해당 part 기준으로 검증되어) 거부되며 유효한
목록 전체가 출력됩니다.

---

## 빠른 시작 (Claude Code 플러그인)

플러그인으로 설치하면 어떤 세션에서든 다음처럼 사용합니다.

```
/vivado-build --xpr /경로/프로젝트.xpr --dry-run
/vivado-build --xpr /경로/프로젝트.xpr
```

이 커맨드는 `run.sh`를 실행한 뒤 `summary.csv`와 타이밍 리포트를 읽어, 순위가
매겨진 사람이 읽기 좋은 비교표와 함께 best strategy를 알려줍니다.

### 대화형 사용 (슬래시 커맨드)

`/vivado-strategy-sweep:vivado-build <프로젝트-디렉터리-또는-.xpr>`를 실행합니다.
커맨드는 프로젝트 `.xpr`을 찾되, `.ipdefs/`, `.gen/`, `.srcs/`, `.ip_user_files/`,
`.runs/` 아래의 IP 내부 `.xpr`은 제외하고 탐색합니다. 그 뒤 `scripts/strategies.txt`의
strategy 목록(`Vivado Implementation Defaults` 기준선 포함)을 체크박스 메뉴로 즉시
보여줍니다. 원하는 항목을 선택하면 각 strategy가 기본 전체 흐름으로 실행됩니다.

**Refresh IP Catalog → upgrade_ip → Generate Output Products → Synthesis →
Implementation → .bit/.ltx/.xsa → Vitis (platform + app + .elf + download.bit,
for timing-PASS strategies).**

`--no-prep-ip` 또는 `--no-vitis`로 해당 단계를 건너뛸 수 있습니다. 공백을 포함한
strategy 이름(예: 기준선)은 run/폴더/CSV/XSA 이름에 사용하기 위해 정규화된 토큰
(`Vivado_Implementation_Defaults`)으로 저장됩니다.

### 회사 PC에서 처음부터 설치하기 (step by step)

> 전제: 회사 PC에 **Vivado 2023.1**, **git**, **Claude Code**가 설치되어 있고,
> 이 저장소는 **private** 입니다.

**1) GitHub 인증 (private 저장소 접근용, 최초 1회)**

터미널에서 git이 이 저장소를 받을 수 있어야 합니다. 가장 간단한 방법은 `gh`
CLI 로그인입니다.

```bash
gh auth login        # GitHub.com → HTTPS → 브라우저 또는 토큰(권한: repo)
```

`gh`가 없다면 git 자격증명만 설정돼 있어도 됩니다. 다음이 되면 통과입니다.

```bash
git ls-remote https://github.com/TAEHYUN9999/vivado-strategy-sweep.git   # 에러 없이 목록이 나오면 OK
```

**2) Claude Code를 열고, 이 저장소를 플러그인 마켓플레이스로 추가**

Claude Code 세션 안에서(프롬프트에) 아래를 입력합니다.

```
/plugin marketplace add TAEHYUN9999/vivado-strategy-sweep
```

**3) 플러그인 설치**

```
/plugin install vivado-strategy-sweep@vivado-strategy-sweep
```

(또는 인자 없이 `/plugin` 만 입력하면 메뉴가 떠서 목록에서 설치할 수도 있습니다.)

**4) 사용**

```
/vivado-build --xpr /회사/실제/프로젝트.xpr --dry-run     # 먼저 검증 (~1분)
/vivado-build --xpr /회사/실제/프로젝트.xpr                # 풀 sweep
```

회사 PC의 Vivado 경로가 다르거나 PATH에 없으면 `--vivado` 로 직접 지정합니다.

```
/vivado-build --xpr /회사/프로젝트.xpr --vivado /tools/Xilinx/Vivado/2023.1/bin/vivado
```

> 경로는 모두 인자로 받기 때문에(`--xpr`, `--vivado`, `--outdir`) 회사 PC의
> 디렉터리 구조가 달라도 그대로 사용할 수 있습니다. 스크립트 자체 경로는
> `${CLAUDE_PLUGIN_ROOT}` 로 자동 해석되므로 어디에 설치되든 동작합니다.

#### 업데이트 / 제거

```
/plugin marketplace update vivado-strategy-sweep     # 최신 커밋 받기
/plugin uninstall vivado-strategy-sweep@vivado-strategy-sweep
```

#### Claude 없이 셸로만 쓰기 (대안)

플러그인 설치 없이도 동일하게 동작합니다.

```bash
git clone https://github.com/TAEHYUN9999/vivado-strategy-sweep.git
cd vivado-strategy-sweep
./scripts/run.sh --xpr /회사/프로젝트.xpr --dry-run
```

플러그인 매니페스트는 [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json),
마켓플레이스 정의는 [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json),
커맨드는 [`commands/vivado-build.md`](commands/vivado-build.md) 에 있습니다.

---

## sweep 동작 방식 (Tcl)

strategy마다 엔진은 아래와 동등한 작업을 수행합니다.

```tcl
create_run impl_<strategy> -parent_run synth_1 -flow <flow> -strategy <strategy>
launch_runs impl_<strategy> -to_step write_bitstream -jobs <N>
wait_on_run impl_<strategy>            ;# 완료까지 블로킹 (batch 모드에서 필수)
```

이후 run에서 `STATS.WNS/TNS/WHS/THS` 를 읽고 리소스 리포트를 파싱한 뒤 비트스트림과
리포트를 꺼내옵니다. (타이밍을 만족한 run 중 WNS가 가장 높은) best run에는 다음을
수행합니다.

```tcl
open_run impl_<best>
write_hw_platform -fixed -include_bit -force impl_<best>.xsa
```

자세한 내용은 [`scripts/sweep.tcl`](scripts/sweep.tcl) 참고.

---

## 참고 / 주의사항

- sweep는 본질적으로 N번의 풀 implementation이라 시간이 오래 걸립니다. 빠른
  반복을 원하면 `strategies.txt`를 줄이세요.
- `launch_runs`는 비블로킹이라, 이 도구는 항상 `wait_on_run`을 호출해 batch 모드가
  먼저 종료되지 않게 합니다.
- `.xsa` 생성은 Vitis 대상 설계(예: 블록 디자인 / MicroBlaze)를 가정합니다.
  핸드오프가 필요 없는 순수 PL 설계라면 `--xsa none`을 쓰세요.
- 홀드(`WHS`/`THS`)를 셋업과 함께 보고하므로, 셋업은 잡았지만 홀드를 깨뜨리는
  strategy를 바로 확인할 수 있습니다.

## Vitis 워크스페이스 / JTAG 굽기

`--vitis-src` 를 주면 **타이밍을 통과한(timing-PASS)** strategy의 `.xsa` 에서
**Vitis 워크스페이스**를 자동 생성합니다 (`<outdir>/<strategy>/vitis/`). 타이밍을
못 맞춘 strategy는 스킵합니다(굽기용이므로).

- `vitispp` — 플랫폼 (BSP 포함, MicroBlaze standalone)
- `vitisap` — 빈 C 앱 + 소스 import + 빌드된 `.elf`
- `vitisap_system` — 시스템 프로젝트
- `download.bit` — 비트스트림 + `.elf` 를 합친 굽기용 파일 (`updatemem`, 펌웨어가
  BRAM에 적재됨). Vitis GUI의 "Program Device → ELF 지정" 과 동일 결과이며,
  프로세서 인스턴스는 `.mmi` 에서 자동 추출합니다.

소스 경로는 직접 주거나(`/경로/펌웨어`), **`auto`** 로 자동탐지합니다. `auto` 는
`.xpr` 디렉터리 아래에서 `vitis_src_ver2` → `vitis/app/src` → `vitis_src` → `src`
순으로 `main.c` 가 있는 폴더를 찾고(없으면 하위 검색), 못 찾으면 Vitis 빌드를
건너뜁니다.

```bash
# 소스 자동탐지 + timing-PASS면 자동 생성:
./scripts/run.sh --xpr /경로/프로젝트.xpr \
    --strategies "Performance_ExplorePostRoutePhysOpt" --vitis-src auto

# 소스 경로를 직접 지정:
./scripts/run.sh --xpr /경로/프로젝트.xpr --vitis-src /경로/펌웨어_C소스
```

만들어진 워크스페이스는 **classic Vitis GUI에서 바로 열립니다**
(`vitis -workspace <outdir>/<strategy>/vitis`).

> ⚠ 처음 열면 **Welcome 탭이 Project Explorer를 덮어** 빈 화면처럼 보입니다.
> **Welcome 탭의 ✕를 닫으면** platform(`vitispp`) + app(`vitisap`) 이 나타납니다.
> platform이 `(Out-of-date)` 면 우클릭 → Build 로 최신화한 뒤 JTAG로 굽습니다.

GUI 없이 헤드리스로 굽고 싶으면 xsct로도 됩니다:

```tcl
connect
fpga -file <outdir>/<strategy>/<strategy>.bit
dow  <outdir>/<strategy>/vitis/vitisap/Debug/vitisap.elf
con
```

> 참고: xsct로 만든 워크스페이스는 platform을 Eclipse 워크스페이스 레지스트리에
> 등록해야 GUI에 보입니다. 이 도구는 `build_vitis.tcl` 에서 `importprojects` 로
> 자동 등록하므로 별도 작업이 필요 없습니다.

---

## Timing troubleshoot

If any swept strategy fails timing (WNS<0 or WHS<0), the sweep extracts the
worst paths to `<strategy>/troubleshoot/violations.json` (net- vs logic-bound,
with cell→RTL source mapping). The `vivado-build` command then writes
review-ready fixes: `xdc/timing_fix.xdc` (net), `hdl/<module>.v.bak` + revision
(logic), and `report.md`. Nothing is applied or rebuilt automatically — review,
copy, recompile. Opt out with `--no-troubleshoot`.

## 라이선스

MIT — [LICENSE](LICENSE) 참고.
