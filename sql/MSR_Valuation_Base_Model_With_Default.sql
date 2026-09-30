-- 1. CREATE LOANS TABLE

CREATE TABLE loans (
    loan_id VARCHAR(20) PRIMARY KEY,
    origination_date DATE,
    original_balance NUMERIC(15,2),
    current_balance NUMERIC(15,2),
    interest_rate NUMERIC(8,4),
    original_term_months INTEGER,
    loan_age_months INTEGER,
    remaining_term_months INTEGER,
    fico_score NUMERIC(6,1),
    ltv_pct NUMERIC(8,4),
    dti_pct NUMERIC(8,4),
    property_state VARCHAR(10),
    property_type VARCHAR(30),
    occupancy VARCHAR(30),
    servicing_fee_rate NUMERIC(10,6),
    delinquency_days INTEGER,
    loan_status VARCHAR(30)
);


-- 2. IMPORT LOANS CSV
-- Import MSR_Loans_1000.csv using pgAdmin Import/Export
-- Header = Yes
-- Format = CSV


-- 3. DATA QUALITY CHECK

SELECT
    loan_id,
    current_balance,
    fico_score,
    property_state,
    servicing_fee_rate,
    remaining_term_months
FROM loans
WHERE current_balance < 0
   OR fico_score IS NULL
   OR property_state = 'XX'
   OR servicing_fee_rate <= 0
   OR remaining_term_months <= 0;


-- 4. CREATE CLEAN LOANS VIEW

CREATE VIEW clean_loans AS
SELECT *
FROM loans
WHERE current_balance >= 0
  AND fico_score IS NOT NULL
  AND property_state <> 'XX'
  AND servicing_fee_rate > 0
  AND remaining_term_months > 0;


-- 5. VERIFY CLEAN PORTFOLIO

SELECT
    COUNT(*) AS total_clean_loans,
    SUM(current_balance) AS total_clean_upb
FROM clean_loans;


SELECT
    ROUND(AVG(interest_rate), 4) AS avg_interest_rate,
    ROUND(AVG(fico_score), 2) AS avg_fico,
    ROUND(AVG(ltv_pct), 2) AS avg_ltv,
    ROUND(AVG(dti_pct), 2) AS avg_dti
FROM clean_loans;


-- 6. CREATE ASSUMPTIONS TABLE

CREATE TABLE msr_assumptions (
    assumption_name VARCHAR(50) PRIMARY KEY,
    assumption_value NUMERIC(12,6)
);


-- 7. INSERT BASE ASSUMPTIONS

INSERT INTO msr_assumptions (
    assumption_name,
    assumption_value
)
VALUES
    ('base_cpr', 0.10),
    ('base_annual_default_rate', 0.02),
    ('base_discount_rate', 0.08),
    ('base_annual_servicing_cost', 60),
    ('base_ancillary_revenue_monthly', 2);


--- For Scenerio Analysis 
/*
Upside: CPR 6%, Default 1%, Discount 7%
Base: CPR 10%, Default 2%, Discount 8%
Stress: CPR 15%, Default 4%, Discount 10%
*/

INSERT INTO msr_assumptions (
    assumption_name,
    assumption_value
)
VALUES
    ('upside_cpr', 0.06),
    ('upside_default_rate', 0.01),
    ('upside_discount_rate', 0.07),

    ('stress_cpr', 0.15),
    ('stress_default_rate', 0.04),
    ('stress_discount_rate', 0.10);

-- 8. CHECK ASSUMPTIONS

SELECT *
FROM msr_assumptions;


-- 9. CALCULATE MONTHLY SMM
--    AND MONTHLY DISCOUNT RATE

SELECT
    1 - POWER(
        1 - MAX(
            CASE
                WHEN assumption_name = 'base_cpr'
                THEN assumption_value
            END
        ),
        1.0 / 12
    ) AS monthly_smm,

    POWER(
        1 + MAX(
            CASE
                WHEN assumption_name = 'base_discount_rate'
                THEN assumption_value
            END
        ),
        1.0 / 12
    ) - 1 AS monthly_discount_rate

FROM msr_assumptions;




--10. FULL PORTFOLIO MSR VALUATION

WITH RECURSIVE

loan_inputs AS (

    SELECT
        loan_id,
        CAST(current_balance AS NUMERIC) AS current_balance,
        interest_rate,
        remaining_term_months,
        servicing_fee_rate,

        -- Convert annual CPR to monthly SMM
        1 - POWER(
            1 - (
                SELECT assumption_value
                FROM msr_assumptions
                WHERE assumption_name = 'base_cpr'
            ),
            1.0 / 12
        ) AS monthly_smm, 

		-- MONTHLY DEFAULT RATE
    1 - POWER(
        1 - (
            SELECT assumption_value
            FROM msr_assumptions
            WHERE assumption_name = 'base_annual_default_rate'
        ),
        1.0 / 12
    ) AS monthly_default_rate,

        -- Fixed monthly mortgage payment
        current_balance
            * (interest_rate / 100.0 / 12)
            / (
                1 - POWER(
                    1 + (interest_rate / 100.0 / 12),
                    -remaining_term_months
                )
            ) AS monthly_payment

    FROM clean_loans

   -- WHERE loan_id = 'LN000001'
),


msr_projection AS (

    -- MONTH 1

    SELECT
        1 AS month_number,
        loan_id,
        current_balance AS beginning_upb,
        interest_rate,
        remaining_term_months,
        servicing_fee_rate,
        monthly_smm,
		monthly_default_rate,
        monthly_payment,

        -- Ending UPB after scheduled principal
        -- expected prepayment
		-- and expected default
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
		* (1 - monthly_default_rate) AS ending_upb

    FROM loan_inputs


    UNION ALL


    -- MONTH 2 ONWARD

    SELECT
        month_number + 1,
        loan_id,
        ending_upb AS beginning_upb,
        interest_rate,
        remaining_term_months,
        servicing_fee_rate,
        monthly_smm,
		monthly_default_rate,
        monthly_payment,

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
		* (1 - monthly_default_rate)AS ending_upb

    FROM msr_projection

    WHERE month_number < remaining_term_months
      AND ending_upb > 0
),


valuation_calc AS (

    SELECT
        *,

        -- MONTHLY MORTGAGE INTEREST

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


        -- EXPECTED PREPAYMENT

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

		-- EXPECTED DEFAULT -- Default Amount=Balance After Scheduled Principal and Prepayment * Monthly Default Rate
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


        -- MONTHLY SERVICING COST

        (
            SELECT assumption_value
            FROM msr_assumptions
            WHERE assumption_name =
                  'base_annual_servicing_cost'
        ) / 12 AS servicing_cost,


        -- 
        -- ANCILLARY REVENUE

        (
            SELECT assumption_value
            FROM msr_assumptions
            WHERE assumption_name =
                  'base_ancillary_revenue_monthly'
        ) AS ancillary_revenue,


        -- NET MSR CASH FLOW =
        -- Servicing Revenue
        -- + Ancillary Revenue
        -- - Servicing Cost

        (
            beginning_upb
                * servicing_fee_rate
                / 12
        )
        +
        (
            SELECT assumption_value
            FROM msr_assumptions
            WHERE assumption_name =
                  'base_ancillary_revenue_monthly'
        )
        -
        (
            (
                SELECT assumption_value
                FROM msr_assumptions
                WHERE assumption_name =
                      'base_annual_servicing_cost'
            ) / 12
        )
        AS net_msr_cash_flow,


        -- MONTHLY DISCOUNT RATE
        -- (1 + annual rate)^(1/12) - 1

        POWER(
            1 + (
                SELECT assumption_value
                FROM msr_assumptions
                WHERE assumption_name =
                      'base_discount_rate'
            ),
            1.0 / 12
        ) - 1 AS monthly_discount_rate,


        -- PRESENT VALUE
        --
        -- PV =
        -- Net MSR Cash Flow/(1 + monthly rate)^n

        (
            (
                beginning_upb
                    * servicing_fee_rate
                    / 12
            )
            +
            (
                SELECT assumption_value
                FROM msr_assumptions
                WHERE assumption_name =
                      'base_ancillary_revenue_monthly'
            )
            -
            (
                (
                    SELECT assumption_value
                    FROM msr_assumptions
                    WHERE assumption_name =
                          'base_annual_servicing_cost'
                ) / 12
            )
        )
        /
        POWER(
            1 + (
                POWER(
                    1 + (
                        SELECT assumption_value
                        FROM msr_assumptions
                        WHERE assumption_name =
                              'base_discount_rate'
                    ),
                    1.0 / 12
                ) - 1
            ),
            month_number
        ) AS present_value

    FROM msr_projection
)

-- TOTAL MSR VALUE FOR LN000001

/*SELECT
    loan_id,
    ROUND(SUM(present_value), 2) AS total_msr_value
FROM valuation_calc
GROUP BY loan_id
ORDER BY loan_id; */

/* Checking to see the calculation logic is working or not for LN000001
   Ending UPB = (Beginning upb - Scheduled principal) - Prepayment - Default 
SELECT
    loan_id,
    month_number,
    ROUND(beginning_upb, 2) AS beginning_upb,
    ROUND(monthly_interest, 2) AS monthly_interest,
    ROUND(scheduled_principal, 2) AS scheduled_principal,
    ROUND(prepayment, 2) AS prepayment,
    ROUND(default_amount, 2) AS default_amount,
    ROUND(ending_upb, 2) AS ending_upb,
    ROUND(net_msr_cash_flow, 2) AS net_msr_cash_flow,
    ROUND(present_value, 2) AS present_value
FROM valuation_calc
WHERE loan_id = 'LN000001'
ORDER BY month_number
LIMIT 5;
*/

SELECT

    -- Number of clean loans
    (
        SELECT COUNT(*)
        FROM clean_loans
    ) AS clean_loans,

    -- Total clean UPB
    ROUND(
        (
            SELECT SUM(current_balance)
            FROM clean_loans
        ),
        2
    ) AS total_clean_upb,

    -- Total portfolio MSR value
    ROUND(
        SUM(present_value),
        2
    ) AS total_msr_value,

    -- MSR value as % of UPB
    ROUND(
        SUM(present_value)
        /
        (
            SELECT SUM(current_balance)
            FROM clean_loans
        )
        * 100,
        4
    ) AS msr_value_pct_upb,

    -- MSR value in basis points
    ROUND(
        SUM(present_value)
        /
        (
            SELECT SUM(current_balance)
            FROM clean_loans
        )
        * 10000,
        2
    ) AS msr_value_bps,

    -- UPB-weighted servicing fee rate
    ROUND(
        (
            SELECT
                SUM(current_balance * servicing_fee_rate)
                / SUM(current_balance)
            FROM clean_loans
        ),
        6
    ) AS weighted_servicing_fee_rate,

	-- Servicing multiple  MSR value / UPB: 0.8825%
		ROUND(
		    (
		        SUM(present_value)
		        /
		        (
		            SELECT SUM(current_balance)
		            FROM clean_loans
		        )
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

FROM valuation_calc;








