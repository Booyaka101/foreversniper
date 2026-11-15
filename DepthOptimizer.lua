local function integer(v, minimum)
    return type(v) == "number" and v == v and v < math.huge
        and v >= minimum and v % 1 == 0
end

ForeverSniperDepthOptimizer = {}

-- Every candidate includes the entire floor through a price tier. Limits may
-- reject a candidate, but never turn it into a partial tier or expand its ceiling.
function ForeverSniperDepthOptimizer.choose(tiers, ceiling, evaluate)
    if not integer(ceiling, 1) then return nil, "invalid" end
    local levels, quantities, total = {}, {}, 0
    for _, tier in ipairs(tiers) do
        if not integer(tier.price, 1) or not integer(tier.quantity, 0) then return nil, "invalid" end
        if tier.quantity > 0 then
            if not quantities[tier.price] then levels[#levels + 1] = tier.price end
            quantities[tier.price] = (quantities[tier.price] or 0) + tier.quantity
            total = total + tier.quantity
        end
    end
    table.sort(levels)
    local units, cost, best, rejected = 0, 0, nil, "empty"
    for i, price in ipairs(levels) do
        if price > ceiling then break end
        units, cost = units + quantities[price], cost + price * quantities[price]
        local terms, reason = evaluate(price, {
            units=units, cost=cost, first=levels[1],
            competing=levels[i + 1], competingUnits=total - units,
        })
        if terms and type(terms.profit) == "number" and terms.profit == terms.profit
            and terms.profit < math.huge then
            if not best or terms.profit > best.profit
                or (terms.profit == best.profit and terms.cost < best.cost) then
                terms.line = price
                best = terms
            end
        else
            rejected = reason or "profit"
        end
    end
    if best then return best end
    return nil, rejected
end
