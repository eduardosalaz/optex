"""Benchmark the four shared models through coptpy (official COPT binding)."""

import coptpy as cp
from coptpy import COPT

import harness
import models

ENV = cp.Envr()


def base_model():
    m = ENV.createModel("bench")
    m.setParam(COPT.Param.Logging, 0)
    m.setParam(COPT.Param.Threads, 1)
    return m


def dispose(m):
    m.clear()


def solve(m):
    m.solve()
    status = "optimal" if m.status == COPT.OPTIMAL else str(m.status)
    return {
        "objective": m.objval,
        "status": status,
        "solver_time_s": round(m.getAttr(COPT.Attr.SolvingTime), 4),
    }


def build_transport(data):
    plants, markets, cost, supply, demand = data
    m = base_model()
    x = m.addVars(plants, markets, lb=0.0)
    for p in plants:
        m.addConstr(cp.quicksum(x[p, mk] for mk in markets) <= supply[p])
    for mk in markets:
        m.addConstr(cp.quicksum(x[p, mk] for p in plants) == demand[mk])
    m.setObjective(
        cp.quicksum(cost[p, mk] * x[p, mk] for p in plants for mk in markets),
        sense=COPT.MINIMIZE,
    )
    return m


def build_assign(data):
    idx, cost = data
    m = base_model()
    m.setParam(COPT.Param.RelGap, 1e-9)
    x = m.addVars(idx, idx, vtype=COPT.BINARY)
    for i in idx:
        m.addConstr(cp.quicksum(x[i, j] for j in idx) == 1)
    for j in idx:
        m.addConstr(cp.quicksum(x[i, j] for i in idx) == 1)
    m.setObjective(
        cp.quicksum(cost[i, j] * x[i, j] for i in idx for j in idx), sense=COPT.MINIMIZE
    )
    return m


def build_portfolio(data):
    idx, q, mu, target = data
    m = base_model()
    x = m.addVars(idx, lb=0.0)
    m.addConstr(cp.quicksum(x[i] for i in idx) == 1)
    m.addConstr(cp.quicksum(mu[i] * x[i] for i in idx) >= target)
    m.setObjective(
        cp.quicksum(c * x[i] * x[j] for (i, j), c in q.items()), sense=COPT.MINIMIZE
    )
    return m


def build_knapsack(data):
    items, w1, w2, w3, value, cap1, cap2, cap3 = data
    m = base_model()
    m.setParam(COPT.Param.RelGap, 1e-9)
    x = m.addVars(items, vtype=COPT.BINARY)
    m.addConstr(cp.quicksum(w1[i] * x[i] for i in items) <= cap1)
    m.addConstr(cp.quicksum(w2[i] * x[i] for i in items) <= cap2)
    m.addConstr(cp.quicksum(w3[i] * x[i] for i in items) <= cap3)
    m.setObjective(cp.quicksum(value[i] * x[i] for i in items), sense=COPT.MAXIMIZE)
    return m


def main():
    results = []
    cases = [
        ("transport", models.transport_data(), build_transport),
        ("assign", models.assign_data(), build_assign),
        ("portfolio", models.portfolio_data(), build_portfolio),
        ("knapsack", models.knapsack_data(), build_knapsack),
    ]
    for name, data, build in cases:
        harness.run_case(results, "coptpy", name, lambda: build(data), solve, dispose)
    harness.write_results(results, "coptpy")


if __name__ == "__main__":
    main()
