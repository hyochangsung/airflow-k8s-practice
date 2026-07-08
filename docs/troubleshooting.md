# 트러블슈팅 (Troubleshooting)

실습 중 자주 만나는 문제와 해결법. 증상 → 원인 → 해결 순서로 정리.

---

## 진단의 기본 3종 세트

무슨 문제든 먼저 이 3개를 본다.

```bash
kubectl get pods -n airflow                 # 어떤 pod가 무슨 상태인가
kubectl describe pod <pod> -n airflow       # 하단 Events에 원인이 찍힌다
kubectl logs <pod> -n airflow               # 컨테이너 로그
# 사이드카가 여러 개인 pod는 컨테이너를 지정:
kubectl logs <pod> -c git-sync -n airflow
```

---

## 1. pod가 `ErrImagePull` / `ImagePullBackOff`

**원인**: 커스텀 이미지를 k3d 클러스터가 못 찾음. `docker build`는 랩탑 Docker에, 클러스터는 별도 Docker에서 돌기 때문.

**해결**
```bash
# 1) 이미지를 클러스터에 import 했는지 확인
k3d image import airflow-k8s-practice:local -c airflow-lab

# 2) values의 태그가 :latest가 아닌지 확인 (latest는 항상 pull 시도 → 실패)
#    → tag: local, pullPolicy: IfNotPresent 로 설정되어 있어야 함

# 3) import 후 pod 재생성
kubectl rollout restart deployment -n airflow
```

---

## 2. DAG가 Airflow UI에 안 보임

**확인 순서**

1. **GitSync가 도는지**
   ```bash
   kubectl get pods -n airflow
   kubectl logs <scheduler-pod> -c git-sync -n airflow   # clone/pull 로그 확인
   ```
2. **subPath가 맞는지**: `dags.gitSync.subPath: "dags"` — repo의 실제 DAG 폴더명과 일치해야 함.
3. **repo/branch가 맞는지**: `repo`, `branch: main` 확인. push한 브랜치와 같아야 함.
4. **DAG 파싱 에러인지**
   ```bash
   kubectl logs <scheduler-pod> -c scheduler -n airflow | grep -i error
   # 또는 UI 상단의 "Import Errors" 배너 확인
   ```
5. **동기화 대기**: `period`(기본 60s, 이 랩은 20s)만큼 기다렸는지. 그래도 안 나오면 스케줄러 DAG 파싱 주기도 고려.

**빠른 강제 갱신**
```bash
kubectl rollout restart deployment/airflow-scheduler -n airflow
```

---

## 3. `docker build` 실패 — constraints URL / 네트워크

**증상**: builder stage에서 `uv pip compile`이 constraints를 못 받아옴.

**원인/해결**
- `AIRFLOW_VERSION`, `PYTHON_VERSION`에 맞는 constraints 파일이 실제 존재하는 URL이어야 한다. 브라우저로 아래를 열어 200이 뜨는지 확인:
  `https://raw.githubusercontent.com/apache/airflow/constraints-2.10.5/constraints-3.12.txt`
- 사내/프록시 네트워크면 빌드 중 외부 접근이 막혔을 수 있음.
- 이미지 태그 조합(`apache/airflow:2.10.5-python3.12`)이 존재하는지 Docker Hub에서 확인.

---

## 4. webserver / scheduler 가 계속 `CrashLoopBackOff`

**흔한 원인 A — DB 마이그레이션 Job 미완료**
```bash
kubectl get jobs -n airflow            # airflow-run-airflow-migrations 가 Complete 인지
kubectl logs job/airflow-run-airflow-migrations -n airflow
```

**흔한 원인 B — 리소스 부족 (랩탑 메모리)**
```bash
kubectl describe pod <pod> -n airflow  # Events에 OOMKilled / Insufficient memory 있는지
```
→ Docker Desktop의 Resources에서 메모리를 늘리거나(예: 6~8GB), 불필요 컴포넌트를 끈다.

**흔한 원인 C — webserver secret key 불일치 (helm upgrade 후)**
→ `helm/airflow-values.yaml`의 "webserver secret key 고정" 주석 섹션 참고. 고정 Secret을 만들어 재현.

---

## 5. `helm install` 이 timeout

**원인**: 이미지 pull/DB 마이그레이션에 시간이 오래 걸려 기본 대기시간(5분)을 초과.

**해결**
```bash
# --wait 없이 설치하고 pod 상태를 직접 관찰하거나,
helm install airflow apache-airflow/airflow -n airflow \
  -f helm/airflow-values.yaml --timeout 15m

# 진행 상황:
kubectl get pods -n airflow -w
```

---

## 6. `port-forward` 접속이 안 됨

```bash
# 1) webserver pod가 Running & Ready 인지
kubectl get pods -n airflow | grep webserver

# 2) 서비스 이름 확인 후 포워딩
kubectl get svc -n airflow
kubectl port-forward svc/airflow-webserver 8080:8080 -n airflow
# → 브라우저에서 http://localhost:8080  (기본 계정 admin / admin)
```
- 이미 8080을 쓰는 프로세스가 있으면 `8081:8080` 처럼 로컬 포트를 바꾼다.

---

## 7. 클러스터를 깨끗이 지우고 처음부터

```bash
helm uninstall airflow -n airflow
kubectl delete namespace airflow
k3d cluster delete airflow-lab
```
