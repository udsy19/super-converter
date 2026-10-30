---
title: A Small Article
author: Grace Hopper
---

## Summary

This fixture mixes the elements of a short article: sections, a list, a table, a formula, code and a quotation.

## Data

The measurements were taken on three machines:

- an older laptop,
- a desktop computer,
- and a small server.

| Machine | Seconds |
|:--------|--------:|
| Laptop | 4.21 |
| Desktop | 2.08 |
| Server | 1.57 |

## Model

The time grows with the number of lines $n$ as

$$t(n) = a n + b \log n,$$

which fits all three machines.

## Code

```
let t = a * Double(n) + b * log(Double(n))
```

> Measure twice, typeset once.
