"""Deterministic model data, mirrored exactly in optex_bench.exs.

All data comes from integer remainder formulas so every language builds
bit-identical coefficients. Data generation happens OUTSIDE build timing.
"""


def transport_data():
    P, M = 300, 400
    plants = range(1, P + 1)
    markets = range(1, M + 1)
    cost = {(p, m): float((p * 31 + m * 17) % 40 + 1) for p in plants for m in markets}
    supply = {p: 170.0 for p in plants}
    demand = {m: float(m * 7 % 50 + 100) for m in markets}
    return plants, markets, cost, supply, demand


def assign_data():
    N = 250
    idx = range(1, N + 1)
    cost = {(i, j): float((i * 53 + j * 71 + i * j) % 100 + 1) for i in idx for j in idx}
    return idx, cost


def portfolio_data():
    N = 300
    idx = range(1, N + 1)
    f = {i: (i * 17 % 23) / 23.0 for i in idx}
    g = {i: (i * 29 % 31) / 31.0 for i in idx}
    d = {i: (i * 13 % 11) / 11.0 + 0.5 for i in idx}
    mu = {i: float(i * 7 % 13 + 1) for i in idx}

    # objective terms over i <= j: literal coefficient of x_i * x_j
    # (off-diagonals doubled so the i <= j expression equals x'Qx)
    q = {}
    for i in idx:
        for j in idx:
            if j < i:
                continue
            v = 4.0 * f[i] * f[j] + 2.0 * g[i] * g[j]
            if i == j:
                v += d[i]
            else:
                v *= 2.0
            q[(i, j)] = v
    return idx, q, mu, 8.0


def knapsack_data():
    items = range(1, 121)
    w1 = {i: i * 7919 % 199 + 11 for i in items}
    w2 = {i: i * 6733 % 211 + 7 for i in items}
    w3 = {i: i * 104729 % 223 + 13 for i in items}
    value = {i: i * 31337 % 197 + 19 for i in items}
    cap1 = sum(w1.values()) // 3
    cap2 = sum(w2.values()) // 3
    cap3 = sum(w3.values()) // 3
    return items, w1, w2, w3, value, cap1, cap2, cap3
