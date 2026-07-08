"""
hello_k8s_dag
=============

airflow-k8s-practice 랩의 검증용 샘플 DAG.

이 DAG의 목적은 딱 하나다:
  "GitHub repo에 push한 DAG가 GitSync를 통해 Airflow에 동기화되고,
   로컬 k3d 클러스터 위에서 실제로 실행되는지" 를 눈으로 확인하는 것.

동작:
  1) 실행 중인 pod의 hostname / Python 버전 등 환경 정보를 로그로 남긴다.
  2) 간단한 계산 결과를 다음 task로 넘긴다 (XCom 동작 확인).
  3) 마지막 task에서 그 값을 받아 최종 메시지를 출력한다.
"""

from __future__ import annotations

import platform
import socket
from datetime import datetime

from airflow.decorators import dag, task


@dag(
    dag_id="hello_k8s_dag",
    # 실행 자동 트리거는 하지 않고, UI에서 수동으로 돌려보며 확인한다.
    schedule=None,
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=["lab", "k8s", "hello"],
    doc_md=__doc__,
)
def hello_k8s():
    @task
    def print_environment() -> dict:
        """실행 중인 컨테이너(pod)의 환경 정보를 로그로 남긴다."""
        info = {
            "hostname": socket.gethostname(),
            "python_version": platform.python_version(),
            "platform": platform.platform(),
        }
        print("=" * 60)
        print(" hello_k8s_dag 가 k3d 클러스터 안에서 실행되고 있습니다! ")
        print("=" * 60)
        for key, value in info.items():
            print(f"  {key:16}: {value}")
        return info

    @task
    def compute(info: dict) -> int:
        """간단한 계산 → XCom으로 다음 task에 값 전달."""
        result = sum(ord(ch) for ch in info["hostname"]) % 100
        print(f"hostname 기반 계산 결과: {result}")
        return result

    @task
    def say_goodbye(result: int) -> None:
        """앞 task에서 받은 값으로 마지막 메시지 출력."""
        print(f"GitSync + k3d + Airflow 파이프라인 검증 완료 ✅ (result={result})")

    say_goodbye(compute(print_environment()))


hello_k8s()
