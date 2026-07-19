"""Benchmark the four shared models through docplex (official CPLEX binding).

Runs on Python 3.10 (.venv310): CPLEX 22.1.1 ships engine wrappers for
Python 3.8-3.10 only.
"""

from docplex.mp.model import Model

import harness
import models


def base_model():
    m = Model(log_output=False)
    m.context.cplex_parameters.threads = 1
    return m


def dispose(m):
    m.end()


def solve(m):
    s = m.solve()
    status = m.solve_details.status
    return {
        "objective": s.objective_value,
        "status": "optimal" if "optimal" in status else status,
        "solver_time_s": round(m.solve_details.time, 4),
    }


def build_transport(data):
    plants, markets, cost, supply, demand = data
    m = base_model()
    x = m.continuous_var_matrix(plants, markets, lb=0)
    m.add_constraints(m.sum(x[p, mk] for mk in markets) <= supply[p] for p in plants)
    m.add_constraints(m.sum(x[p, mk] for p in plants) == demand[mk] for mk in markets)
    m.minimize(m.sum(cost[p, mk] * x[p, mk] for p in plants for mk in markets))
    return m


def build_assign(data):
    idx, cost = data
    m = base_model()
    m.parameters.mip.tolerances.mipgap = 1e-9
    x = m.binary_var_matrix(idx, idx)
    m.add_constraints(m.sum(x[i, j] for j in idx) == 1 for i in idx)
    m.add_constraints(m.sum(x[i, j] for i in idx) == 1 for j in idx)
    m.minimize(m.sum(cost[i, j] * x[i, j] for i in idx for j in idx))
    return m


def build_portfolio(data):
    idx, q, mu, target = data
    m = base_model()
    x = m.continuous_var_dict(idx, lb=0)
    m.add_constraint(m.sum(x[i] for i in idx) == 1)
    m.add_constraint(m.sum(mu[i] * x[i] for i in idx) >= target)
    m.minimize(m.sum(c * x[i] * x[j] for (i, j), c in q.items()))
    return m


def build_knapsack(data):
    items, w1, w2, w3, value, cap1, cap2, cap3 = data
    m = base_model()
    m.parameters.mip.tolerances.mipgap = 1e-9
    x = m.binary_var_dict(items)
    m.add_constraint(m.sum(w1[i] * x[i] for i in items) <= cap1)
    m.add_constraint(m.sum(w2[i] * x[i] for i in items) <= cap2)
    m.add_constraint(m.sum(w3[i] * x[i] for i in items) <= cap3)
    m.maximize(m.sum(value[i] * x[i] for i in items))
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
        harness.run_case(results, "docplex", name, lambda: build(data), solve, dispose)
    harness.write_results(results, "docplex")


if __name__ == "__main__":
    main()
