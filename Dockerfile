# syntax=docker/dockerfile:1

# =============================================================================
# 커스텀 Airflow 이미지 (multi-stage build)
#
#   Stage 1 (builder) : 컴파일 도구(build-essential) + uv 로
#                       의존성을 "wheel"(미리 빌드된 설치 파일)로 만든다.
#   Stage 2 (final)   : 컴파일 도구 없이, builder가 만든 wheel만 오프라인 설치.
#
# 왜 이렇게 나누나?
#   최종 이미지에 gcc 같은 build 의존성을 남기지 않기 위해서다.
#   → 이미지가 작아지고(레이어 최적화), 공격 표면(attack surface)도 줄어든다.
#   자세한 이유는 README의 "Docker layer 최적화" 섹션 참고.
# =============================================================================

ARG AIRFLOW_VERSION=2.10.5
ARG PYTHON_VERSION=3.12

# ===== Stage 1: builder / wheelhouse =========================================
FROM apache/airflow:${AIRFLOW_VERSION}-python${PYTHON_VERSION} AS builder

ARG AIRFLOW_VERSION
ARG PYTHON_VERSION

# uv 바이너리를 공식 이미지에서 그대로 복사한다 (pip 대신 쓰는 빠른 installer).
#   재현성을 원하면 :latest 대신 :0.5.x 처럼 버전을 고정하는 것을 권장.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# apt 패키지 설치와 캐시 삭제를 반드시 "같은 RUN 레이어"에서 처리한다.
#   다른 RUN으로 나누면, 나중에 삭제해도 이전 레이어에 캐시가 그대로 남아
#   최종 이미지 크기가 커진다. (Docker 레이어는 append-only)
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*
USER airflow

# Airflow 팀이 검증한 버전 조합(constraints)으로 의존성을 고정한다.
#   → "의존성 지옥"(서로 호환 안 되는 버전 조합)을 방지.
ARG CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"

WORKDIR /opt/build
COPY pyproject.toml ./pyproject.toml

# 1) pyproject(=원하는 것) → requirements.lock(=완전히 고정된 버전 목록) 생성
RUN uv pip compile pyproject.toml \
      --constraint "${CONSTRAINT_URL}" \
      --output-file requirements.lock

# 2) lockfile 기준으로 모든 의존성을 wheel로 미리 빌드한다.
#    (소스 컴파일이 필요한 패키지가 있다면, 그 작업은 오직 이 builder stage에서만 발생)
RUN uv pip wheel -r requirements.lock --wheel-dir /opt/build/wheels


# ===== Stage 2: final runtime ================================================
FROM apache/airflow:${AIRFLOW_VERSION}-python${PYTHON_VERSION} AS final

# 설치에만 쓸 uv 바이너리를 잠깐 가져온다 (설치가 끝나면 아래에서 삭제).
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# builder가 만든 wheel과 lockfile만 가져온다.
#   → 소스코드/컴파일러(build-essential)는 최종 이미지로 넘어오지 않는다.
COPY --from=builder /opt/build/wheels /opt/build/wheels
COPY --from=builder /opt/build/requirements.lock /opt/build/requirements.lock

# 오프라인(--no-index)으로 wheel에서만 설치한다.
#   - --no-index      : PyPI에 접속하지 않고 로컬 wheel만 사용 → 재현성/속도 ↑
#   - --find-links    : wheel이 들어있는 폴더 지정
#   - --system        : 베이스 이미지의 시스템 python 환경에 설치
#   - airflow 본체는 베이스 이미지에 이미 동일 버전으로 있으므로 재설치되지 않는다.
# 설치가 끝나면 wheel/lock/uv 바이너리까지 같은 RUN에서 삭제해 레이어를 깔끔하게 유지.
USER root
RUN uv pip install --system --no-cache \
      --no-index --find-links=/opt/build/wheels \
      -r /opt/build/requirements.lock \
 && rm -rf /opt/build/wheels /opt/build/requirements.lock \
           /usr/local/bin/uv /usr/local/bin/uvx
USER airflow
