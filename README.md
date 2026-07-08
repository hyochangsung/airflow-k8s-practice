# airflow-k8s-practice

로컬 Kubernetes(k3d) 위에 **Apache Airflow를 공식 Helm chart로 배포**하고,
**최적화된 커스텀 Docker 이미지**와 **GitSync 기반 DAG 동기화**를 검증하는 실습 랩.

> 단순히 Airflow를 실행하는 것이 목적이 아니라, **실제 회사에서 쓰는 배포 흐름
> (컨테이너 → 이미지 최적화 → k8s → Helm → GitOps 스타일 DAG 배포)** 을
> 로컬에서 작게 재현하는 것이 목표다.

---

## 🎯 프로젝트 목표

1. 개인 랩탑에서 Kubernetes 클러스터 실행 (k3d)
2. Airflow 공식 Helm chart로 Airflow 배포
3. multi-stage build로 최적화된 커스텀 Airflow Docker 이미지 작성
4. 그 이미지를 로컬 k3d 클러스터에 로드
5. GitSync로 GitHub repo의 DAG를 Airflow에 동기화
6. Airflow UI에서 DAG가 보이고 실행되는 것까지 확인
7. 전체 과정을 재현 가능한 형태로 문서화

---

## 🗺️ 전체 아키텍처

```
┌───────────────────────────── 내 랩탑 ──────────────────────────────┐
│                                                                           │
│   ┌── Docker Desktop ──────────────────────────────────────────────────┐  │
│   │                                                                     │  │
│   │   docker build ──▶  airflow-k8s-practice:local  (커스텀 이미지)     │  │
│   │        │                                                            │  │
│   │        │  k3d image import                                          │  │
│   │        ▼                                                            │  │
│   │   ┌── k3d 클러스터 "airflow-lab" (k3s in Docker) ─────────────────┐ │  │
│   │   │                                                              │ │  │
│   │   │   Helm release "airflow" (LocalExecutor)                     │ │  │
│   │   │   ┌────────────┐  ┌────────────┐  ┌───────────┐              │ │  │
│   │   │   │ scheduler  │  │ webserver  │  │ triggerer │  + postgres  │ │  │
│   │   │   │  +git-sync │  │  +git-sync │  │           │              │ │  │
│   │   │   └─────┬──────┘  └─────┬──────┘  └───────────┘              │ │  │
│   │   └─────────┼───────────────┼──────────────────────────────────┘ │  │
│   └─────────────┼───────────────┼────────────────────────────────────┘  │
│                 │ git pull      │ port-forward 8080                       │
└─────────────────┼───────────────┼───────────────────────────────────────┘
                  ▼               ▼
      GitHub: airflow-k8s-practice/dags     브라우저 http://localhost:8080
      (DAG의 source of truth)               (Airflow UI)
```

**흐름 한 줄 요약**: `git push` → GitSync가 pull → Airflow가 DAG 인식 → UI에서 실행 확인.

---

## 📂 Repo 구조

```
airflow-k8s-practice/
├── README.md                 # 이 문서 (실습 기록/재현 가이드)
├── Dockerfile                # multi-stage 커스텀 Airflow 이미지
├── pyproject.toml            # Python 의존성 "선언"(manifest)
├── .dockerignore
├── dags/
│   └── hello_k8s_dag.py      # GitSync로 동기화되는 검증용 DAG
├── helm/
│   └── airflow-values.yaml   # 공식 차트 override 값 (커스텀 이미지 + GitSync)
└── docs/
    ├── concepts.md           # k3s/k3d/kubectl/kubeconfig/Helm/GitSync 개념
    └── troubleshooting.md    # 문제 해결 모음
```

핵심 개념(k3s·k3d·kubectl·kubeconfig·Helm·GitSync)은 **[docs/concepts.md](docs/concepts.md)** 에 자세히 정리했다.

---

## 🧱 Docker 이미지 최적화 설명

이 랩의 [`Dockerfile`](Dockerfile)은 **multi-stage build**로 되어 있다.

| 원칙 | 어떻게 | 왜 |
| --- | --- | --- |
| build 의존성 격리 | builder stage에서만 `build-essential` 설치, final stage에는 없음 | 최종 이미지에 gcc/헤더가 안 남아 **작고 안전** |
| wheelhouse 패턴 | builder가 의존성을 `wheel`로 미리 빌드 → final은 오프라인 설치 | 컴파일을 빌드 단계로 몰고, 런타임 이미지 슬림화 |
| apt 캐시 즉시 삭제 | `apt-get install ... && apt-get clean && rm -rf /var/lib/apt/lists/*` 를 **같은 RUN**에서 | 레이어는 append-only라, RUN 나누면 캐시가 이전 레이어에 남음 |
| pip/uv 캐시 미보존 | `--no-cache` / `--no-index --find-links` | 캐시 파일이 이미지에 안 남음, 재현성↑ |
| 버전 고정 | Airflow `constraints` + `uv pip compile`로 lockfile 생성 | "누가 언제 빌드해도 같은 이미지" (재현성) |

> 의존성은 `pyproject.toml`(원하는 것) → `requirements.lock`(고정된 것) → 설치, 로 분리한다.
> installer는 `pip` 대신 **`uv`**(훨씬 빠른 Python 패키지 매니저)를 사용한다.
> 자세한 이유는 [docs/concepts.md #8](docs/concepts.md) 참고.

---

## ✅ 사전 준비 (Prerequisites)

| 도구 | 용도 | 설치 |
| --- | --- | --- |
| Docker Desktop | 컨테이너 런타임 | https://www.docker.com/products/docker-desktop |
| k3d | 로컬 k8s 클러스터 | `brew install k3d` |
| kubectl | k8s CLI | `brew install kubectl` |
| helm | k8s 패키지 매니저 | `brew install helm` |

```bash
# 설치 확인
docker version && k3d version && kubectl version --client && helm version
```

---

## 🚀 실행 순서 (Step by step)

### Step 0. 저장소 클론
```bash
git clone https://github.com/hyochangsung/airflow-k8s-practice.git
cd airflow-k8s-practice
```

### Step 1. k3d 클러스터 생성
```bash
k3d cluster create airflow-lab

# 확인
kubectl get nodes          # STATUS 가 Ready 여야 함
kubectl config current-context   # k3d-airflow-lab 를 가리켜야 함
```

### Step 2. 커스텀 Airflow 이미지 빌드
```bash
docker build -t airflow-k8s-practice:local .

# 확인
docker images | grep airflow-k8s-practice
```

### Step 3. 이미지를 k3d 클러스터에 로드
> `docker build`로 만든 이미지는 클러스터가 자동으로 알지 못한다. 명시적으로 주입한다.
```bash
k3d image import airflow-k8s-practice:local -c airflow-lab
```

### Step 4. Airflow Helm 차트 저장소 추가
```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update
```

### Step 5. Airflow 설치
```bash
kubectl create namespace airflow

helm install airflow apache-airflow/airflow \
  --namespace airflow \
  -f helm/airflow-values.yaml \
  --timeout 15m

# 진행 상황 관찰 (모든 pod가 Running/Completed 될 때까지)
kubectl get pods -n airflow -w
```

### Step 6. DAG 동기화 확인 (GitSync)
```bash
# git-sync 사이드카가 repo를 pull 하는지 확인
kubectl get pods -n airflow
kubectl logs deploy/airflow-scheduler -c git-sync -n airflow
```
`dags/` 폴더의 `hello_k8s_dag`가 동기화된다. DAG를 새로 push하면 `period`(20s) 주기로 반영된다.

### Step 7. Airflow UI 접속
```bash
kubectl port-forward svc/airflow-webserver 8080:8080 -n airflow
```
브라우저에서 **http://localhost:8080** 접속 → 기본 계정 **admin / admin** →
`hello_k8s_dag`가 목록에 보이면 성공. DAG를 켜고(Unpause) ▶ 실행 → 로그에서 실행 확인.

---

## 🔄 DAG 갱신 흐름 (GitOps 스타일)

```bash
# dags/ 에 DAG를 추가/수정 후
git add dags/ && git commit -m "add new dag" && git push

# → GitSync가 자동으로 pull → 20초 내 UI에 반영
```
이미지 재빌드도, 재배포도 필요 없다. **DAG 배포 = git push**.

---

## 🔁 설정 변경 후 업그레이드

```bash
# helm/airflow-values.yaml 을 수정한 뒤
helm upgrade airflow apache-airflow/airflow \
  --namespace airflow \
  -f helm/airflow-values.yaml
```

이미지를 다시 빌드했다면:
```bash
docker build -t airflow-k8s-practice:local .
k3d image import airflow-k8s-practice:local -c airflow-lab
kubectl rollout restart deployment -n airflow
```

---

## 🧪 검증 체크리스트

- [ ] `k3d cluster create airflow-lab` 로 클러스터 생성됨
- [ ] `kubectl get nodes` 에서 노드가 **Ready**
- [ ] `docker build -t airflow-k8s-practice:local .` 성공
- [ ] `k3d image import ...` 로 이미지가 클러스터에 주입됨
- [ ] `helm install` 후 airflow pod들이 **Running/Completed**
- [ ] scheduler pod의 `git-sync` 컨테이너가 repo를 정상 pull
- [ ] `dags/` 에 push한 DAG가 **Airflow UI에 표시**됨
- [ ] `kubectl port-forward` 로 UI(http://localhost:8080) 접속됨
- [ ] `hello_k8s_dag` 를 실행하면 로그에 완료 메시지가 찍힘
- [ ] 이 README만 보고 다른 사람이 처음부터 재현 가능

---

## 🔐 (Optional) Private repo를 SSH로 동기화하기

public repo는 HTTPS로 자격증명 없이 clone된다. private repo라면 SSH 키가 필요하다.

```bash
# 1) 배포용 SSH 키 생성
ssh-keygen -t ed25519 -f ./airflow-deploy-key -N ""

# 2) 공개키(airflow-deploy-key.pub)를 GitHub repo → Settings → Deploy keys 에 등록

# 3) 개인키를 k8s Secret으로 등록
kubectl create secret generic airflow-git-ssh-secret \
  --from-file=gitSshKey=./airflow-deploy-key \
  -n airflow
```

그 다음 `helm/airflow-values.yaml`의 `gitSync`를 SSH 방식으로 교체
(파일 안의 주석 처리된 "Optional private repo (SSH)" 섹션 참고):

```yaml
dags:
  gitSync:
    enabled: true
    repo: git@github.com:hyochangsung/airflow-k8s-practice.git
    branch: main
    subPath: "dags"
    sshKeySecret: airflow-git-ssh-secret
```

```bash
helm upgrade airflow apache-airflow/airflow -n airflow -f helm/airflow-values.yaml
```

---

## 🏭 Production 확장 방향 (개념만)

이 랩은 **로컬 재현**에 집중하므로 아래는 구현하지 않고 개념만 정리한다.
(로컬에서 `kubectl port-forward`로 UI에 붙는 것이, 아래 흐름의 축소판이다.)

- **VPN**: 클러스터 API를 공개 인터넷에 노출하지 않고, 사내망에 들어와야만 접근 가능하게.
- **Bastion host (점프 서버)**: 내부 리소스에 직접 붙지 못하게 하고, 통제/감사되는 단일 관문을 거치게.
- **Internal DNS**: `airflow.internal.company.com` 같은 내부 도메인으로 서비스 디스커버리. IP가 바뀌어도 이름은 고정.
- **그 외**: Terraform으로 인프라 코드화(IaC), 이미지 레지스트리(ECR/GCR), Secret 관리(Vault/External Secrets), 관측(Prometheus/Grafana).

> 이번 실습의 핵심은 **로컬 Kubernetes + Airflow Helm chart + 커스텀 Docker 이미지 + GitSync**다.
> Terraform·VPN·Bastion·DNS는 위처럼 개념으로만 남긴다.

---

## 🧹 정리 (클린업)

```bash
helm uninstall airflow -n airflow
kubectl delete namespace airflow
k3d cluster delete airflow-lab
```

---

## 🆘 트러블슈팅

자주 만나는 문제와 해결법은 **[docs/troubleshooting.md](docs/troubleshooting.md)** 에 정리했다.
(ImagePullBackOff, DAG 안 보임, CrashLoopBackOff, port-forward 실패 등)
