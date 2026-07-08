# 개념 정리 (Concepts)

이 랩에서 등장하는 핵심 개념을 "왜 필요한가" 중심으로 정리한다.

---

## 1. 컨테이너 → 오케스트레이션 큰 그림

```
Docker (컨테이너 1개 실행)
   ↓  여러 개를 여러 서버에 걸쳐 자동 배치/복구/확장하고 싶다
Kubernetes (컨테이너 오케스트레이터)
   ↓  로컬 랩탑에서 가볍게 돌리고 싶다
k3s (경량 Kubernetes 배포판)
   ↓  k3s를 Docker 위에서 손쉽게 띄우고 싶다
k3d (k3s in Docker 실행 도구)
```

---

## 2. k3s

- **정의**: Rancher(SUSE)가 만든 **경량 Kubernetes 배포판**. CNCF 인증 k8s이면서 바이너리 하나로 동작.
- **왜 가벼운가**: etcd 대신 SQLite 사용 가능, 불필요한 in-tree 클라우드 드라이버 제거, 단일 바이너리(<100MB).
- **어디에 쓰나**: 엣지/IoT, 개발환경, CI, 학습용. 표준 k8s API를 그대로 제공하므로 여기서 배운 게 실무 k8s로 이어진다.

## 3. k3d

- **정의**: k3s 클러스터를 **Docker 컨테이너로** 띄워주는 래퍼(wrapper) CLI.
- **왜 쓰나**: 노드 하나하나가 Docker 컨테이너라서, 클러스터 생성/삭제가 몇 초. 여러 클러스터를 격리해서 실험 가능.
- **핵심 명령**
  ```bash
  k3d cluster create airflow-lab     # 클러스터 생성
  k3d cluster list                   # 목록
  k3d image import <img> -c airflow-lab   # 로컬 이미지를 클러스터 노드로 주입
  k3d cluster delete airflow-lab     # 삭제
  ```
- **k3d image import가 중요한 이유**: k3d 노드는 내 랩탑의 Docker 데몬과 **분리된** 별도 Docker 안에서 돈다. 그래서 `docker build`로 만든 이미지가 클러스터에는 안 보인다. `k3d image import`로 명시적으로 넣어줘야 pod가 그 이미지를 쓸 수 있다.

## 4. kubectl

- **정의**: Kubernetes API 서버와 대화하는 **공식 CLI**.
- **자주 쓰는 명령**
  ```bash
  kubectl get nodes                  # 클러스터 노드 확인
  kubectl get pods -n airflow        # airflow 네임스페이스 pod 상태
  kubectl logs <pod> -n airflow      # 로그
  kubectl describe pod <pod> -n airflow   # 이벤트/에러 원인
  kubectl port-forward svc/airflow-webserver 8080:8080 -n airflow  # UI 접속
  ```

## 5. kubeconfig

- **정의**: kubectl이 "**어느 클러스터에, 어떤 사용자로, 어떻게 인증해서**" 접속할지 담은 설정 파일. 기본 위치는 `~/.kube/config`.
- **구성 3요소**
  - `clusters`: API 서버 주소 + CA 인증서
  - `users`: 인증 정보(토큰/인증서)
  - `contexts`: (cluster + user + namespace) 묶음. 현재 context가 "지금 명령이 날아가는 대상".
- **k3d와의 관계**: `k3d cluster create`가 끝나면 자동으로 kubeconfig에 새 context를 추가하고 현재 context로 전환해준다.
  ```bash
  kubectl config current-context     # 지금 어디를 보고 있나
  kubectl config get-contexts        # 전체 목록
  kubectl config use-context <name>  # 전환
  ```
- **실무 연결점**: 회사에서는 이 kubeconfig가 EKS/GKE 같은 원격 클러스터를 가리키고, 접근은 VPN/bastion을 거친다(아래 8번 참고).

## 6. Helm

- **정의**: Kubernetes용 **패키지 매니저**. 여러 YAML(매니페스트) 묶음을 "chart"라는 패키지로 관리.
- **왜 쓰나**: Airflow를 순수 YAML로 배포하려면 Deployment/Service/Secret/ConfigMap/Job 등 수십 개를 직접 써야 한다. Helm chart는 이걸 파라미터화해서 `values.yaml` 몇 줄로 조립해준다.
- **핵심 용어**
  - **Chart**: 템플릿 + 기본값 묶음 (설치 가능한 패키지)
  - **Values**: chart를 커스터마이즈하는 입력값 (`-f airflow-values.yaml`)
  - **Release**: chart를 클러스터에 설치한 "인스턴스" (이름을 붙여 관리)
- **핵심 명령**
  ```bash
  helm repo add apache-airflow https://airflow.apache.org
  helm repo update
  helm install airflow apache-airflow/airflow -n airflow -f helm/airflow-values.yaml
  helm upgrade airflow apache-airflow/airflow -n airflow -f helm/airflow-values.yaml
  helm uninstall airflow -n airflow
  ```

## 7. GitSync

- **정의**: Git repo를 주기적으로 `pull`해서 로컬 디렉토리에 동기화하는 **사이드카 컨테이너**(Google의 `git-sync`).
- **Airflow에서의 역할**: DAG 파일을 이미지에 굽거나 PVC에 넣지 않고, **GitHub repo를 진실의 원천(source of truth)** 으로 삼는다. repo에 push → GitSync가 pull → Airflow가 새 DAG 인식.
- **장점**
  - DAG 배포 = `git push` (별도 파이프라인 불필요)
  - 버전 관리/리뷰/롤백이 git 그대로
  - 이미지 재빌드 없이 DAG만 갱신
- **이 랩 설정 요지** (`helm/airflow-values.yaml`)
  - `dags.persistence.enabled=false` (PVC 안 씀)
  - `dags.gitSync.enabled=true`
  - `subPath: dags` → repo의 `dags/` 폴더만 DAG 폴더로 인식
  - public repo는 HTTPS로 바로, private repo는 SSH 키(Secret) 필요

---

## 8. Docker 레이어 최적화 (이 랩의 Dockerfile 설계 이유)

Docker 이미지는 **레이어(layer)의 append-only 스택**이다. 한 번 만들어진 레이어는 이후에 파일을 지워도 **이전 레이어에는 그대로 남는다**. 그래서:

- **apt 캐시는 "같은 RUN"에서 삭제해야 한다**
  ```dockerfile
  RUN apt-get update \
   && apt-get install -y --no-install-recommends build-essential \
   && apt-get clean \
   && rm -rf /var/lib/apt/lists/*     # ← 같은 RUN 레이어 안에서 삭제해야 효과 있음
  ```
  RUN을 나누면 삭제 레이어가 따로 생겨도 캐시가 남은 레이어가 이미지에 포함된다.

- **multi-stage build로 build 의존성을 격리한다**
  - builder stage: `build-essential`(gcc 등)로 wheel 컴파일
  - final stage: 컴파일러 없이 완성된 wheel만 설치
  - → 최종 이미지에 gcc/헤더 파일 같은 게 안 남아 **작고 안전**해진다.

- **`--no-cache-dir` / `--no-index`로 불필요한 캐시를 안 남긴다**
  - pip/uv 캐시가 이미지에 남지 않게.
  - `--no-index`는 PyPI 대신 로컬 wheel만 사용 → 재현성과 빌드 속도 ↑.

**왜 신경 쓰나**: 이미지가 작을수록 → push/pull 빠르고 → 노드 디스크 절약 → 배포/스케일 속도 ↑ → 취약점 표면 ↓.

---

## 9. 실무(Production) 확장 개념 — 이 랩에서는 구현하지 않음

로컬에서는 `kubectl`이 랩탑에서 클러스터에 바로 붙는다. 하지만 회사 환경은 보안상 그럴 수 없다.

- **VPN**: 사내망 밖에서 내부 클러스터 API에 접근하려면 먼저 VPN으로 사내망에 들어와야 한다. (클러스터 API를 공개 인터넷에 노출하지 않음)
- **Bastion host (점프 서버)**: 클러스터/DB 같은 내부 리소스에 직접 붙지 못하게 하고, 감사·통제가 되는 **단일 관문 서버**를 거치게 한다. 관리자는 bastion에 SSH → 거기서 kubectl.
- **Internal DNS**: `airflow.internal.company.com` 같은 내부 도메인으로 서비스를 부른다. IP는 바뀌어도 이름은 고정 → 서비스 디스커버리/설정 안정성.

> 이 랩은 위 3가지를 **개념으로만** 다루고, 실제로는 로컬 k3d로 대체한다.
> 로컬에서 `kubectl port-forward`로 UI에 접속하는 것이, 운영에서 VPN+bastion을 거쳐
> 내부 서비스에 접근하는 흐름의 "축소판"이라고 이해하면 된다.
