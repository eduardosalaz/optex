"""Benchmark the four shared models through highspy (official HiGHS binding).

The QP objective goes through passHessian, highspy's official route for
quadratics (the expression layer is linear-only). HiGHS expects
1/2 x'Qx, so literal coefficients get the diagonal doubled, exactly the
conversion Optex's HiGHS binding performs internally.
"""

import highspy

import harness
import models


def base_model():
    h = highspy.Highs()
    h.silent()
    h.setOptionValue("threads", 1)
    return h


def dispose(h):
    h.clear()


def solve(h):
    h.run()
    status = h.modelStatusToString(h.getModelStatus()).lower()
    return {
        "objective": h.getObjectiveValue(),
        "status": status,
        "solver_time_s": round(h.getRunTime(), 4),
    }


def build_transport(data):
    plants, markets, cost, supply, demand = data
    h = base_model()
    x = h.addVariables(plants, markets, lb=0.0)
    h.addConstrs(h.qsum(x[p, mk] for mk in markets) <= supply[p] for p in plants)
    h.addConstrs(h.qsum(x[p, mk] for p in plants) == demand[mk] for mk in markets)
    h.setObjective(
        h.qsum(cost[p, mk] * x[p, mk] for p in plants for mk in markets),
        sense=highspy.ObjSense.kMinimize,
    )
    return h


def build_assign(data):
    idx, cost = data
    h = base_model()
    h.setOptionValue("mip_rel_gap", 1e-9)
    x = h.addBinaries(idx, idx)
    h.addConstrs(h.qsum(x[i, j] for j in idx) == 1 for i in idx)
    h.addConstrs(h.qsum(x[i, j] for i in idx) == 1 for j in idx)
    h.setObjective(
        h.qsum(cost[i, j] * x[i, j] for i in idx for j in idx),
        sense=highspy.ObjSense.kMinimize,
    )
    return h


def build_portfolio(data):
    idx, q, mu, target = data
    n = len(idx)
    h = base_model()
    x = h.addVariables(idx, lb=0.0)
    h.addConstr(h.qsum(x[i] for i in idx) == 1)
    h.addConstr(h.qsum(mu[i] * x[i] for i in idx) >= target)

    # lower-triangular CSC hessian of 1/2 x'Qx from literal coefficients:
    # diagonal doubled, off-diagonals literal
    start, index, value = [], [], []
    for j in range(1, n + 1):
        start.append(len(index))
        for i in range(j, n + 1):
            index.append(i - 1)
            value.append(2.0 * q[(j, i)] if i == j else q[(j, i)])
    start.append(len(index))

    hessian = highspy.HighsHessian()
    hessian.dim_ = n
    hessian.format_ = highspy.HessianFormat.kTriangular
    hessian.start_ = start
    hessian.index_ = index
    hessian.value_ = value
    h.passHessian(hessian)
    return h


def build_knapsack(data):
    items, w1, w2, w3, value, cap1, cap2, cap3 = data
    h = base_model()
    h.setOptionValue("mip_rel_gap", 1e-9)
    x = h.addBinaries(items)
    h.addConstr(h.qsum(w1[i] * x[i] for i in items) <= cap1)
    h.addConstr(h.qsum(w2[i] * x[i] for i in items) <= cap2)
    h.addConstr(h.qsum(w3[i] * x[i] for i in items) <= cap3)
    h.setObjective(
        h.qsum(value[i] * x[i] for i in items), sense=highspy.ObjSense.kMaximize
    )
    return h


def main():
    results = []
    cases = [
        ("transport", models.transport_data(), build_transport),
        ("assign", models.assign_data(), build_assign),
        ("portfolio", models.portfolio_data(), build_portfolio),
        ("knapsack", models.knapsack_data(), build_knapsack),
    ]
    for name, data, build in cases:
        harness.run_case(results, "highspy", name, lambda: build(data), solve, dispose)
    harness.write_results(results, "highspy")


if __name__ == "__main__":
    main()
