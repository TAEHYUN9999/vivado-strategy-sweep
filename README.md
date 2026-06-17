# vivado-strategy-sweep

명령어 하나로 **Vivado implementation strategy를 일괄(sweep) 실행**하고, 타이밍을
비교한 뒤 가장 좋은 결과물을 패키징하는 도구입니다.

합성(synthesis)은 **한 번만** 수행하고, 그 결과를 공유하는 여러 implementation
run(`impl_<strategy>`)을 strategy별로 따로 생성해 비교 가능하게 만듭니다.
각 strategy마다 다음을 수집합니다.

- **타이밍**: WNS / TNS / WHS / THS / TPWS 와 PASS/FAIL 판정
- **리소스**: CLB LUTs, CLB Registers, Block RAM, DSPs
- **산출물**: `.bit` 비트스트림 + 라우팅 후 타이밍/리소스 리포트

마지막으로 타이밍이 가장 좋은 run에 대해 **`.xsa`** 하드웨어 핸드오프(비트스트림
포함)를 생성합니다 — Vitis에서 바로 사용 가능합니다.

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

# 풀 sweep (오래 걸림: 합성 1회 + strategy 개수만큼 implementation):
./scripts/run.sh --xpr /경로/프로젝트.xpr

# strategy/jobs 지정, strategy별로 XSA 생성:
./scripts/run.sh --xpr /경로/프로젝트.xpr \
    --strategies "Performance_Explore,Performance_ExtraTimingOpt" \
    --jobs 8 --xsa all
```

결과는 `vivado_sweep_<타임스탬프>/` 에 저장됩니다.

```
summary.csv                     # 비교표
impl_<strategy>.bit             # strategy별 비트스트림
impl_<strategy>_timing_summary.rpt
impl_<strategy>_utilization.rpt
impl_<best>.xsa                 # 하드웨어 핸드오프 (비트스트림 포함)
vivado.log / vivado.jou         # Vivado batch 전체 로그
```

### 옵션

| 옵션 | 기본값 | 설명 |
|--------|---------|------|
| `--xpr PATH` | `$VB_XPR` | Vivado 프로젝트 (필수) |
| `--strategies "a,b,c"` | `scripts/strategies.txt` | sweep할 strategy 목록 |
| `--jobs N` | `min(8, nproc)` | `launch_runs` 의 `-jobs` 값 |
| `--outdir DIR` | `./vivado_sweep_<ts>` | 출력 디렉터리 |
| `--synth-strategy NAME` | (변경 안 함) | `synth_1` strategy 덮어쓰기 |
| `--xsa best\|all\|none` | `best` | 어떤 run에 `.xsa`를 만들지 |
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

### 설치

Claude Code 플러그인 위치에 clone 하거나, Claude Code 플러그인 문서에 따라 이
저장소를 플러그인 소스/마켓플레이스로 추가하세요. 플러그인 매니페스트는
[`.claude-plugin/plugin.json`](.claude-plugin/plugin.json), 커맨드는
[`commands/vivado-build.md`](commands/vivado-build.md) 에 있습니다.

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

## 라이선스

MIT — [LICENSE](LICENSE) 참고.
