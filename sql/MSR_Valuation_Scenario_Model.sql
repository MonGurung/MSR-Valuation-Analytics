WITH RECURSIVE scenario_assumptions AS (

    SELECT
        'Upside' AS scenario,

        (
            SELECT assumption_value
            FROM msr_assumptions
            WHERE assumption_name = 'upside_cpr'
        ) AS annual_cpr,

        (
            SELECT assumption_value
            FROM msr_assumptions
            WHERE assumption_name = 'upside_default_rate'
        ) AS annual_default_rate,

        (
            SELECT assumption_value
            FROM msr_assumptions
            WHERE assumption_name = 'upside_discount_rate'
        ) AS annual_discount_rate

    UNION ALL

    SELECT
        'Base',

        (
            SELECT assumption_value
            FROM msr_assumptions
            WHERE assumption_name = 'base_cpr'
        ),

        (
            SELECT assumption_value
            FROM msr_assumptions
            WHERE assumption_name = 'base_annual_default_rate'
        ),

        (
            SELECT assumption_value
            FROM msr_assumptions
            WHERE assumption_name = 'base_discount_rate'
        )

    UNION ALL

    SELECT
        'Stress',

        (
            SELECT assumption_value
            FROM msr_assumptions
            WHERE assumption_name = 'stress_cpr'
        ),

        (
            SELECT assumption_value
            FROM msr_assumptions
            WHERE assumption_name = 'stress_default_rate'
        ),

        (
            SELECT assumption_value
            FROM msr_assumptions
            WHERE assumption_name = 'stress_discount_rate'
        )
),

loan_inputs AS (

    SELECT
        c.loan_id,
        c.current_balance,
        c.interest_rate,
        c.remaining_term_months,
        c.servicing_fee_rate,

        s.scenario,

        -- Monthly SMM
        1 - POWER(
            1 - s.annual_cpr,
            1.0 / 12
        ) AS monthly_smm,

        -- Monthly default rate
        1 - POWER(
            1 - s.annual_default_rate,
            1.0 / 12
        ) AS monthly_default_rate,

        -- Monthly discount rate
        POWER(
            1 + s.annual_discount_rate,
            1.0 / 12
        ) - 1 AS monthly_discount_rate,

        -- Mortgage payment
        c.current_balance
            * (c.interest_rate / 100.0 / 12)
            / (
                1 - POWER(
                    1 + (c.interest_rate / 100.0 / 12),
                    -c.remaining_term_months
                )
            ) AS monthly_payment

    FROM clean_loans c
    CROSS JOIN scenario_assumptions s
),

msr_projection AS (

    -- MONTH 1

    SELECT
        1 AS month_number,
        loan_id,
        scenario,
        CAST(current_balance AS NUMERIC) AS beginning_upb,
        interest_rate,
        remaining_term_months,
        servicing_fee_rate,
        monthly_smm,
        monthly_default_rate,
        monthly_discount_rate,
        monthly_payment,

        -- Ending UPB after scheduled principal,
        -- prepayment and default
        GREATEST(
            0,
            current_balance
            - LEAST(
                monthly_payment
                    - current_balance
                    * (interest_rate / 100.0 / 12),
                current_balance
            )
        )
        * (1 - monthly_smm)
        * (1 - monthly_default_rate)
        AS ending_upb

    FROM loan_inputs


    UNION ALL


    -- MONTH 2 ONWARD

    SELECT
        month_number + 1,
        loan_id,
        scenario,
        ending_upb AS beginning_upb,
        interest_rate,
        remaining_term_months,
        servicing_fee_rate,
        monthly_smm,
        monthly_default_rate,
        monthly_discount_rate,
        monthly_payment,

        -- Ending UPB after scheduled principal,
        -- prepayment and default
        GREATEST(
            0,
            ending_upb
            - LEAST(
                monthly_payment
                    - ending_upb
                    * (interest_rate / 100.0 / 12),
                ending_upb
            )
        )
        * (1 - monthly_smm)
        * (1 - monthly_default_rate)
        AS ending_upb

    FROM msr_projection

    WHERE month_number < remaining_term_months
      AND ending_upb > 0
),

valuation_calc AS (

    SELECT
        *,

        -- MONTHLY INTEREST

        beginning_upb
            * (interest_rate / 100.0 / 12)
            AS monthly_interest,

        -- SCHEDULED PRINCIPAL

        LEAST(
            monthly_payment
                - beginning_upb
                * (interest_rate / 100.0 / 12),
            beginning_upb
        ) AS scheduled_principal,

        -- BALANCE BEFORE PREPAYMENT

        GREATEST(
            0,
            beginning_upb
            - LEAST(
                monthly_payment
                    - beginning_upb
                    * (interest_rate / 100.0 / 12),
                beginning_upb
            )
        ) AS balance_before_prepayment,

        -- PREPAYMENT

        GREATEST(
            0,
            beginning_upb
            - LEAST(
                monthly_payment
                    - beginning_upb
                    * (interest_rate / 100.0 / 12),
                beginning_upb
            )
        )
        * monthly_smm AS prepayment,

        -- EXPECTED DEFAULT

        (
            GREATEST(
                0,
                beginning_upb
                - LEAST(
                    monthly_payment
                        - beginning_upb
                        * (interest_rate / 100.0 / 12),
                    beginning_upb
                )
            )
            * (1 - monthly_smm)
        )
        * monthly_default_rate AS default_amount,

        -- SERVICING REVENUE

        beginning_upb
            * servicing_fee_rate
            / 12
            AS servicing_revenue,

        -- SERVICING COST

        (
            SELECT assumption_value
            FROM msr_assumptions
            WHERE assumption_name = 'base_annual_servicing_cost'
        ) / 12 AS servicing_cost,

        -- ANCILLARY REVENUE

        (
            SELECT assumption_value
            FROM msr_assumptions
            WHERE assumption_name = 'base_ancillary_revenue_monthly'
        ) AS ancillary_revenue,

        -- NET MSR CASH FLOW

        (
            beginning_upb * servicing_fee_rate / 12
        )
        +
        (
            SELECT assumption_value
            FROM msr_assumptions
            WHERE assumption_name = 'base_ancillary_revenue_monthly'
        )
        -
        (
            (
                SELECT assumption_value
                FROM msr_assumptions
                WHERE assumption_name = 'base_annual_servicing_cost'
            ) / 12
        )
        AS net_msr_cash_flow,

        -- PRESENT VALUE

        (
            (
                beginning_upb * servicing_fee_rate / 12
            )
            +
            (
                SELECT assumption_value
                FROM msr_assumptions
                WHERE assumption_name = 'base_ancillary_revenue_monthly'
            )
            -
            (
                (
                    SELECT assumption_value
                    FROM msr_assumptions
                    WHERE assumption_name = 'base_annual_servicing_cost'
                ) / 12
            )
        )
        /
        POWER(
            1 + monthly_discount_rate,
            month_number
        ) AS present_value

    FROM msr_projection
),


scenario_summary AS (

    SELECT
        scenario,

        ROUND(
            SUM(present_value),
            2
        ) AS total_msr_value,

        ROUND(
            SUM(present_value)
            / (SELECT SUM(current_balance) FROM clean_loans)
            * 100,
            4
        ) AS msr_value_pct_upb,

        ROUND(
            SUM(present_value)
            / (SELECT SUM(current_balance) FROM clean_loans)
            * 10000,
            2
        ) AS msr_value_bps,

        ROUND(
            (
                SUM(present_value)
                / (SELECT SUM(current_balance) FROM clean_loans)
            )
            /
            (
                SELECT
                    SUM(current_balance * servicing_fee_rate)
                    / SUM(current_balance)
                FROM clean_loans
            ),
            2
        ) AS servicing_multiple

    FROM valuation_calc
    GROUP BY scenario
)

SELECT
    scenario,
    total_msr_value,
    msr_value_pct_upb,
    msr_value_bps,
    servicing_multiple,

    ROUND(
        total_msr_value
        - (
            SELECT total_msr_value
            FROM scenario_summary
            WHERE scenario = 'Base'
        ),
        2
    ) AS dollar_change_vs_base,

    ROUND(
        (
            total_msr_value
            / (
                SELECT total_msr_value
                FROM scenario_summary
                WHERE scenario = 'Base'
            )
            - 1
        ) * 100,
        2
    ) AS pct_change_vs_base

FROM scenario_summary

ORDER BY
    CASE scenario
        WHEN 'Upside' THEN 1
        WHEN 'Base' THEN 2
        WHEN 'Stress' THEN 3
    END;

