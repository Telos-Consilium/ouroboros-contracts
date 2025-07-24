#!/usr/bin/env python3
import sys
from decimal import Decimal, getcontext

# Set high precision
getcontext().prec = 50


def _format_result(value: Decimal) -> str:
    # Convert Decimal to integer
    int_value = int(value)

    # Convert to hexadecimal and pad to 32 bytes (64 hex characters)
    hex_value = hex(int_value)[2:].zfill(64)

    return "0x" + hex_value


def _calculate_compound_yield(
    principal: Decimal, rate_ppm: Decimal, time_seconds: Decimal
) -> Decimal:
    # Convert PPM to decimal rate
    daily_rate = rate_ppm / Decimal("1000000")

    # Convert time to days
    time_days = time_seconds / Decimal("86400")

    # Compound interest formula: A = P(1 + r)^t
    final_amount = principal * ((Decimal("1") + daily_rate) ** time_days)

    return final_amount


def _calculate_linear_yield(
    principal: Decimal, rate_ppm: Decimal, time_seconds: Decimal
) -> Decimal:
    # Match Solidity implementation: poolSize * dailyLinearYieldRatePpm * elapsedTime / (1e6 * 86400)
    # This gives us: principal + (principal * rate_ppm * time_seconds) / (1e6 * 86400)

    # Calculate the yield portion
    yield_amount = (principal * rate_ppm * time_seconds) / (
        Decimal("1000000") * Decimal("86400")
    )

    # Return principal + yield
    return principal + yield_amount


def _calculate_share_price(
    pool_size: Decimal, total_supply: Decimal, rate_ppm: Decimal, time_seconds: Decimal
) -> Decimal:
    # Calculate total assets after yield using linear yield (matching Solidity)
    total_assets = _calculate_compound_yield(pool_size, rate_ppm, time_seconds)

    # Share price = totalAssets / totalSupply * 1e18
    share_price_e18 = (total_assets * Decimal("1000000000000000000")) / total_supply

    return share_price_e18


def calculate_compound_yield(principal: str, rate_ppm: str, time_seconds: str) -> str:
    principal = Decimal(principal)
    rate_ppm = Decimal(rate_ppm)
    time_seconds = Decimal(time_seconds)

    # Calculate compound yield
    final_amount = _calculate_compound_yield(principal, rate_ppm, time_seconds)

    # Return the final amount as a hexadecimal string
    return _format_result(final_amount)


def calculate_linear_yield(principal: str, rate_ppm: str, time_seconds: str) -> str:
    principal = Decimal(principal)
    rate_ppm = Decimal(rate_ppm)
    time_seconds = Decimal(time_seconds)

    # Calculate linear yield (matching Solidity implementation)
    final_amount = _calculate_linear_yield(principal, rate_ppm, time_seconds)

    # Return the final amount as a hexadecimal string
    return _format_result(final_amount)


def calculate_share_price(
    pool_size: str, total_supply: str, rate_ppm: str, time_seconds: str
) -> str:
    if total_supply == "0":
        return _format_result(Decimal("1000000000000000000"))

    pool_size_decimal = Decimal(pool_size)
    total_supply_decimal = Decimal(total_supply)
    rate_ppm_decimal = Decimal(rate_ppm)
    time_seconds_decimal = Decimal(time_seconds)

    # Calculate share price
    share_price_e18 = _calculate_share_price(
        pool_size_decimal, total_supply_decimal, rate_ppm_decimal, time_seconds_decimal
    )

    # Return the share price as a hexadecimal string
    return _format_result(share_price_e18)


if __name__ == "__main__":
    try:
        if len(sys.argv) < 2:
            print("0x0", end="")
            sys.exit(1)

        command = sys.argv[1]

        if command == "compound_yield":
            if len(sys.argv) != 5:
                print("0x0", end="")
                sys.exit(1)
            principal = sys.argv[2]
            rate_ppm = sys.argv[3]
            time_seconds = sys.argv[4]
            result = calculate_compound_yield(principal, rate_ppm, time_seconds)
            print(result, end="")

        elif command == "linear_yield":
            if len(sys.argv) != 5:
                print("0x0", end="")
                sys.exit(1)
            principal = sys.argv[2]
            rate_ppm = sys.argv[3]
            time_seconds = sys.argv[4]
            result = calculate_linear_yield(principal, rate_ppm, time_seconds)
            print(result, end="")

        elif command == "share_price":
            if len(sys.argv) != 6:
                print("0x0", end="")
                sys.exit(1)
            pool_size = sys.argv[2]
            total_supply = sys.argv[3]
            rate_ppm = sys.argv[4]
            time_seconds = sys.argv[5]
            result = calculate_share_price(
                pool_size, total_supply, rate_ppm, time_seconds
            )
            print(result, end="")

        else:
            print("0x0", end="")
            sys.exit(1)

    except Exception as e:
        # Print a default hex value on any error
        print("0x0", end="")
        sys.exit(1)
