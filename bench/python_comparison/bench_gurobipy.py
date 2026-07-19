"""Benchmark the four shared models through gurobipy (official Gurobi binding)."""

import gurobipy as gp
from gurobipy import GRB, quicksum

import harness
import models


def base_model():
    m = gp.Model()
    m.Params.OutputFlag = 0
    m.Params.Threads = 1
    return m


def dispose(m):
    m.dispose()


def solve(m):
    m.optimize()
    status = {GRB.OPTIMAL: "optimal"}.get(m.Status, str(m.Status))
    return {"objective": m.ObjVal, "status": status, "solver_time_s": round(m.Runtime, 4)}


def build_transport(data):
    plants, markets, cost, supply, demand = data
    m = base_model()
    x = m.addVars(plants, markets, lb=0.0)
    m.addConstrs(quicksum(x[p, mk] for mk in markets) <= supply[p] for p in plants)
    m.addConstrs(quicksum(x[p, mk] for p in plants) == demand[mk] for mk in markets)
    m.setObjective(
        quicksum(cost[p, mk] * x[p, mk] for p in plants for mk in markets), GRB.MINIMIZE
    )
    return m


def build_assign(data):
    idx, cost = data
    m = base_model()
    m.Params.MIPGap = 1e-9
    x = m.addVars(idx, idx, vtype=GRB.BINARY)
    m.addConstrs(quicksum(x[i, j] for j in idx) == 1 for i in idx)
    m.addConstrs(quicksum(x[i, j] for i in idx) == 1 for j in idx)
    m.setObjective(quicksum(cost[i, j] * x[i, j] for i in idx for j in idx), GRB.MINIMIZE)
    return m


def build_portfolio(data):
    idx, q, mu, target = data
    m = base_model()
    x = m.addVars(idx, lb=0.0)
    m.addConstr(quicksum(x[i] for i in idx) == 1)
    m.addConstr(quicksum(mu[i] * x[i] for i in idx) >= target)
    m.setObjective(quicksum(c * x[i] * x[j] for (i, j), c in q.items()), GRB.MINIMIZE)
    return m


def build_knapsack(data):
    items, w1, w2, w3, value, cap1, cap2, cap3 = data
    m = base_model()
    m.Params.MIPGap = 1e-9
    x = m.addVars(items, vtype=GRB.BINARY)
    m.addConstr(quicksum(w1[i] * x[i] for i in items) <= cap1)
    m.addConstr(quicksum(w2[i] * x[i] for i in items) <= cap2)
    m.addConstr(quicksum(w3[i] * x[i] for i in items) <= cap3)
    m.setObjective(quicksum(value[i] * x[i] for i in items), GRB.MAXIMIZE)
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
        harness.run_case(results, "gurobipy", name, lambda: build(data), solve, dispose)
    harness.write_results(results, "gurobipy")


if __name__ == "__main__":
    main()
