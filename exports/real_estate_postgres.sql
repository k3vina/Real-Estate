/* =====================================================================
   Capstone: Location or Renovation?  (King County, WA)
   PostgreSQL script: staging, loading, checks, clean_sales view,
   modeling queries and exports.

   INPUT : real_estate_clean.csv  (16 columns, one row per sale, already
           joined with the Census ZIP income and cleaned in Power Query)

   HOW TO RUN (psql):
     1. Edit the \cd path in PART 1 to the folder that holds the CSV.
     2. From a terminal:   psql -U postgres -d real_estate -f real_estate_postgres.sql
        (create the database first:  CREATE DATABASE real_estate;)
     Run it part by part the first time and compare each check with the
     "EXPECT" comment beside it.

   pgAdmin users: \copy only works in psql. Run everything except the
   \copy lines, and use the Import/Export tool for the load (PART 1) and
   the exports (PART 9). Settings: CSV, header ON, delimiter ",".

   Every table and view lives in the schema "capstone".
   ===================================================================== */


/* =====================================================================
   PART 0. SETUP AND RESET
   Dropping only removes this project's own objects. The CSV is never
   changed.
   ===================================================================== */
CREATE SCHEMA IF NOT EXISTS capstone;
SET search_path TO capstone, public;

DROP VIEW  IF EXISTS underpriced_candidates CASCADE;
DROP VIEW  IF EXISTS clean_sales            CASCADE;
DROP VIEW  IF EXISTS zip_income_quartile    CASCADE;
DROP TABLE IF EXISTS sales_typed            CASCADE;
DROP TABLE IF EXISTS stg_real_estate_raw    CASCADE;

CREATE TABLE IF NOT EXISTS pipeline_log (
    step_no      serial PRIMARY KEY,
    step         text,
    object_name  text,
    row_count    bigint,
    note         text,
    logged_at    timestamptz DEFAULT now()
);
TRUNCATE pipeline_log RESTART IDENTITY;


/* =====================================================================
   PART 1. STAGING AND LOADING
   Every column is TEXT, so the raw file lands exactly as it is, with
   nothing converted or rejected. Column order must match the CSV.
   ===================================================================== */
CREATE TABLE stg_real_estate_raw (
    excise_tax_nbr    text,
    major             text,
    minor             text,
    sale_price        text,
    sale_year         text,
    zip_code          text,
    bldg_grade        text,
    condition_code    text,
    yr_built          text,
    yr_renovated      text,
    sqft_tot_living   text,
    bedrooms          text,
    median_income     text,
    price_per_sqft    text,
    renovation_status text,
    renovation_flag   text
);

-- >>> EDIT THIS PATH <<<  (use forward slashes, even on Windows)
\cd 'C:/Users/HP/Documents/Real Estate/data'

-- Client-side load: reads the file from YOUR computer, so no server file
-- permissions are needed.
\copy stg_real_estate_raw FROM 'real_estate_clean.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

INSERT INTO pipeline_log (step, object_name, row_count, note)
SELECT 'load', 'stg_real_estate_raw', count(*), 'rows read from the CSV'
FROM stg_real_estate_raw;

-- CHECK 1.  EXPECT: 108990 rows
SELECT count(*) AS staged_rows FROM stg_real_estate_raw;

-- CHECK 2.  Blank values per column.  EXPECT: 0 in every column
SELECT
    count(*) FILTER (WHERE trim(coalesce(excise_tax_nbr,'')) = '')    AS blank_excise,
    count(*) FILTER (WHERE trim(coalesce(major,'')) = '')             AS blank_major,
    count(*) FILTER (WHERE trim(coalesce(minor,'')) = '')             AS blank_minor,
    count(*) FILTER (WHERE trim(coalesce(sale_price,'')) = '')        AS blank_price,
    count(*) FILTER (WHERE trim(coalesce(zip_code,'')) = '')          AS blank_zip,
    count(*) FILTER (WHERE trim(coalesce(sqft_tot_living,'')) = '')   AS blank_sqft,
    count(*) FILTER (WHERE trim(coalesce(median_income,'')) = '')     AS blank_income
FROM stg_real_estate_raw;

-- CHECK 3.  Leading zeros survived.  EXPECT: major length 6, minor length 4,
--           zip length 5, every row
SELECT length(major) AS major_len, length(minor) AS minor_len,
       length(zip_code) AS zip_len, count(*) AS n
FROM stg_real_estate_raw
GROUP BY 1,2,3;


/* =====================================================================
   PART 2. TYPED TABLE
   Casts the staging text into proper types and adds sanity constraints.
   If a constraint fails, the INSERT stops and names the problem, which
   means the file contains a value you should look at.
   ===================================================================== */
CREATE TABLE sales_typed (
    sale_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    excise_tax_nbr    integer      NOT NULL,
    major             varchar(6)   NOT NULL CHECK (length(major) = 6),
    minor             varchar(4)   NOT NULL CHECK (length(minor) = 4),
    sale_price        integer      NOT NULL CHECK (sale_price > 0),
    sale_year         smallint     NOT NULL CHECK (sale_year BETWEEN 2020 AND 2026),
    zip_code          char(5)      NOT NULL,
    bldg_grade        smallint     NOT NULL CHECK (bldg_grade BETWEEN 1 AND 13),
    condition_code    smallint     NOT NULL CHECK (condition_code BETWEEN 1 AND 5),
    yr_built          smallint     NOT NULL,
    yr_renovated      smallint     NOT NULL DEFAULT 0,
    sqft_tot_living   integer      NOT NULL CHECK (sqft_tot_living > 0),
    bedrooms          smallint     NOT NULL CHECK (bedrooms >= 0),
    median_income     integer      NOT NULL CHECK (median_income > 0),
    price_per_sqft_src numeric(10,2) NOT NULL,   -- value as supplied in the CSV
    renovation_status text         NOT NULL,
    renovation_flag   smallint     NOT NULL CHECK (renovation_flag IN (0,1)),
    UNIQUE (excise_tax_nbr, major, minor)
);

INSERT INTO sales_typed (
    excise_tax_nbr, major, minor, sale_price, sale_year, zip_code,
    bldg_grade, condition_code, yr_built, yr_renovated, sqft_tot_living,
    bedrooms, median_income, price_per_sqft_src, renovation_status, renovation_flag)
SELECT
    trim(excise_tax_nbr)::integer, trim(major), trim(minor),
    trim(sale_price)::integer, trim(sale_year)::smallint, trim(zip_code),
    trim(bldg_grade)::smallint, trim(condition_code)::smallint,
    trim(yr_built)::smallint, trim(yr_renovated)::smallint,
    trim(sqft_tot_living)::integer, trim(bedrooms)::smallint,
    trim(median_income)::integer, trim(price_per_sqft)::numeric,
    trim(renovation_status), trim(renovation_flag)::smallint
FROM stg_real_estate_raw;

INSERT INTO pipeline_log (step, object_name, row_count, note)
SELECT 'typed', 'sales_typed', count(*), 'after casting and constraints' FROM sales_typed;

-- CHECK 4.  Staging and typed counts must match.  EXPECT: both 108990, diff 0
SELECT (SELECT count(*) FROM stg_real_estate_raw) AS staged,
       (SELECT count(*) FROM sales_typed)         AS typed,
       (SELECT count(*) FROM stg_real_estate_raw)
     - (SELECT count(*) FROM sales_typed)         AS difference;


/* =====================================================================
   PART 3. DATA UNDERSTANDING
   Row count, null count and ranges (proposal: count(*) and count(col)).
   ===================================================================== */
-- 3a. Rows and non-null counts.  EXPECT: every count equals the row count
SELECT count(*)                AS total_rows,
       count(sale_price)       AS sale_price,
       count(sqft_tot_living)  AS sqft,
       count(bldg_grade)       AS grade,
       count(condition_code)   AS condition_code,
       count(yr_built)         AS yr_built,
       count(yr_renovated)     AS yr_renovated,
       count(median_income)    AS median_income
FROM sales_typed;

-- 3b. Ranges and averages
SELECT 'sale_price' AS col, min(sale_price)::numeric AS min, round(avg(sale_price),0) AS mean,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY sale_price)::numeric AS median,
       max(sale_price)::numeric AS max, round(stddev_samp(sale_price),0) AS sd FROM sales_typed
UNION ALL
SELECT 'sqft_tot_living', min(sqft_tot_living), round(avg(sqft_tot_living),0),
       percentile_cont(0.5) WITHIN GROUP (ORDER BY sqft_tot_living)::numeric,
       max(sqft_tot_living), round(stddev_samp(sqft_tot_living),0) FROM sales_typed
UNION ALL
SELECT 'price_per_sqft', min(price_per_sqft_src), round(avg(price_per_sqft_src),2),
       percentile_cont(0.5) WITHIN GROUP (ORDER BY price_per_sqft_src)::numeric,
       max(price_per_sqft_src), round(stddev_samp(price_per_sqft_src),2) FROM sales_typed;

-- 3c. Sales per year.  EXPECT: 2020 to 2026 only (2026 is a partial year)
SELECT sale_year, count(*) AS sales FROM sales_typed GROUP BY 1 ORDER BY 1;

-- 3d. Histogram of price per sq ft ($100 bins), for the Excel/Tableau chart
SELECT (floor(price_per_sqft_src/100)*100)::int AS bin_start, count(*) AS sales
FROM sales_typed GROUP BY 1 ORDER BY 1;

-- 3e. Grade and condition distributions
SELECT bldg_grade, count(*) AS sales FROM sales_typed GROUP BY 1 ORDER BY 1;
SELECT condition_code, count(*) AS sales FROM sales_typed GROUP BY 1 ORDER BY 1;

-- 3f. Does the supplied price per sq ft match price / sqft?  EXPECT: 0 rows off by more than 1 cent
SELECT count(*) AS mismatched_rows
FROM sales_typed
WHERE abs(price_per_sqft_src - sale_price::numeric / sqft_tot_living) > 0.01;

-- 3g. Does each ZIP have exactly one income?  EXPECT: 0 rows
SELECT zip_code, count(DISTINCT median_income) AS incomes
FROM sales_typed GROUP BY 1 HAVING count(DISTINCT median_income) > 1;

-- 3h. Date logic problems (reported, then excluded in clean_sales)
SELECT
    count(*) FILTER (WHERE yr_built > sale_year)                         AS built_after_sale,
    count(*) FILTER (WHERE yr_renovated > sale_year)                     AS renovated_after_sale,
    count(*) FILTER (WHERE yr_built > sale_year OR yr_renovated > sale_year) AS either_problem,
    count(*) FILTER (WHERE yr_renovated > 0 AND yr_renovated < yr_built) AS renovated_before_built
FROM sales_typed;
-- EXPECT: built_after_sale 306, renovated_after_sale 243, renovated_before_built 0


/* =====================================================================
   PART 4. ZIP INCOME QUARTILES
   Quartiles are cut across ZIPs (one row per ZIP), not across sales, so
   ZIPs with many sales do not move the boundaries.
   Quartile 1 = lowest income ZIPs, 4 = highest. Ties are broken by ZIP.
   ===================================================================== */
CREATE VIEW zip_income_quartile AS
SELECT zip_code,
       median_income,
       NTILE(4) OVER (ORDER BY median_income, zip_code) AS income_quartile
FROM (SELECT DISTINCT zip_code, median_income FROM sales_typed) z;

-- CHECK 5.  EXPECT: 88 ZIPs in total, 22 per quartile
SELECT income_quartile, count(*) AS zips,
       min(median_income) AS min_income, max(median_income) AS max_income
FROM zip_income_quartile GROUP BY 1 ORDER BY 1;


/* =====================================================================
   PART 5. clean_sales VIEW
   Rules applied, with the reason for each:
     - Excludes sales where the home was built after the sale year or
       renovated after the sale year. The price then describes a
       different house (or a pre-sale), and a post-sale renovation would
       wrongly count as "renovated" in the renovation test.
     - Everything else was already cleaned upstream (non-market sales,
       price and size outliers, 2020 to 2026 range).
   Derived columns: price_per_sqft, income_quartile, grade_band,
   renovated_flag, sale_year, above_county_median.
   To keep the flagged rows instead, delete the WHERE clause in "base".
   ===================================================================== */
CREATE VIEW clean_sales AS
WITH base AS (
    SELECT *
    FROM sales_typed
    WHERE yr_built <= sale_year
      AND (yr_renovated = 0 OR yr_renovated <= sale_year)
),
med AS (
    SELECT percentile_cont(0.5) WITHIN GROUP
           (ORDER BY round(sale_price::numeric / sqft_tot_living, 2)) AS county_median_ppsf
    FROM base
)
SELECT
    b.sale_id,
    b.excise_tax_nbr,
    b.major,
    b.minor,
    b.sale_year,
    b.zip_code,
    b.sale_price,
    b.sqft_tot_living,
    round(b.sale_price::numeric / b.sqft_tot_living, 2)           AS price_per_sqft,
    b.bldg_grade,
    CASE WHEN b.bldg_grade <= 6 THEN '1_Low (3-6)'
         WHEN b.bldg_grade  = 7 THEN '2_Average (7)'
         WHEN b.bldg_grade  = 8 THEN '3_Good (8)'
         ELSE                        '4_High (9-13)' END           AS grade_band,
    b.condition_code,
    b.yr_built,
    b.yr_renovated,
    b.renovation_flag                                              AS renovated_flag,
    b.bedrooms,
    b.median_income,
    q.income_quartile,
    CASE WHEN round(b.sale_price::numeric / b.sqft_tot_living, 2) > m.county_median_ppsf
         THEN 1 ELSE 0 END                                         AS above_county_median,
    round(m.county_median_ppsf::numeric, 2)                        AS county_median_ppsf
FROM base b
JOIN zip_income_quartile q USING (zip_code)
CROSS JOIN med m;

-- Row counts for the proposal's before/after reporting
INSERT INTO pipeline_log (step, object_name, row_count, note)
SELECT 'view', 'clean_sales', count(*), 'after excluding impossible build/renovation dates'
FROM clean_sales;

-- CHECK 6.  Where the rows went.  EXPECT: kept + excluded = 108990
SELECT (SELECT count(*) FROM sales_typed) AS before_rows,
       (SELECT count(*) FROM clean_sales) AS after_rows,
       (SELECT count(*) FROM sales_typed) - (SELECT count(*) FROM clean_sales) AS excluded;

-- CHECK 7.  The join to the quartile table must not lose or duplicate rows.
--           EXPECT: equal numbers
SELECT (SELECT count(*) FROM sales_typed
        WHERE yr_built <= sale_year AND (yr_renovated = 0 OR yr_renovated <= sale_year)) AS rows_before_join,
       (SELECT count(*) FROM clean_sales)                                               AS rows_after_join;

-- CHECK 8.  Quartile and band balance
SELECT income_quartile, count(*) AS sales FROM clean_sales GROUP BY 1 ORDER BY 1;
SELECT grade_band,      count(*) AS sales FROM clean_sales GROUP BY 1 ORDER BY 1;


/* =====================================================================
   PART 6. MODELING (probability and correlation only)
   ===================================================================== */

-- 6a. Pearson correlation with price per sq ft
--     Hypothesis: |r| for income is larger than |r| for grade.
SELECT count(*)                                              AS n,
       round(corr(price_per_sqft, median_income)::numeric, 4) AS r_income,
       round(corr(price_per_sqft, bldg_grade)::numeric, 4)    AS r_grade,
       round((corr(price_per_sqft, median_income)^2)::numeric, 4) AS r2_income,
       round((corr(price_per_sqft, bldg_grade)^2)::numeric, 4)    AS r2_grade,
       abs(corr(price_per_sqft, median_income)) > abs(corr(price_per_sqft, bldg_grade)) AS income_stronger
FROM clean_sales;

-- 6b. Spearman correlation = Pearson on ranks.
--     rank() gives tied values the lowest rank, so the average rank is built
--     by adding (ties - 1) / 2, which is the correct Spearman treatment.
WITH ranked AS (
    SELECT
        rank() OVER (ORDER BY price_per_sqft)
          + (count(*) OVER (PARTITION BY price_per_sqft) - 1) / 2.0 AS rk_price,
        rank() OVER (ORDER BY median_income)
          + (count(*) OVER (PARTITION BY median_income) - 1) / 2.0  AS rk_income,
        rank() OVER (ORDER BY bldg_grade)
          + (count(*) OVER (PARTITION BY bldg_grade) - 1) / 2.0     AS rk_grade
    FROM clean_sales
)
SELECT count(*)                                         AS n,
       round(corr(rk_price, rk_income)::numeric, 4)      AS spearman_income,
       round(corr(rk_price, rk_grade)::numeric, 4)       AS spearman_grade,
       abs(corr(rk_price, rk_income)) > abs(corr(rk_price, rk_grade)) AS income_stronger
FROM ranked;

-- 6c. Supplement: ZIP-level correlation (income is measured per ZIP, so this
--     asks the neighbourhood question directly). One row per ZIP.
WITH z AS (
    SELECT zip_code, median_income, avg(price_per_sqft) AS avg_ppsf, count(*) AS n
    FROM clean_sales GROUP BY 1, 2
)
SELECT count(*) AS zips,
       round(corr(avg_ppsf, median_income)::numeric, 4) AS r_zip_income
FROM z;

-- 6d. Conditional probability
--     P(sale above county median $/sqft | top income quartile) vs bottom quartile
SELECT income_quartile,
       count(*)                                          AS n_sales,
       count(*) FILTER (WHERE above_county_median = 1)   AS n_above_median,
       round(count(*) FILTER (WHERE above_county_median = 1)::numeric / count(*), 4) AS p_above_median
FROM clean_sales
GROUP BY 1 ORDER BY 1;

-- 6e. Same comparison, top vs bottom only, plus the difference
SELECT
    round(max(p) FILTER (WHERE income_quartile = 4), 4) AS p_top,
    round(max(p) FILTER (WHERE income_quartile = 1), 4) AS p_bottom,
    round(max(p) FILTER (WHERE income_quartile = 4)
        - max(p) FILTER (WHERE income_quartile = 1), 4) AS difference
FROM (SELECT income_quartile,
             count(*) FILTER (WHERE above_county_median = 1)::numeric / count(*) AS p
      FROM clean_sales GROUP BY 1) t;


/* =====================================================================
   PART 7. NUMBERS TO CROSS-CHECK THE EXCEL TESTS (alpha = 0.05)
   Excel does the official tests. These give the inputs and let you
   confirm Excel is reading the right data.
   ===================================================================== */

-- 7a. ANOVA inputs: group size, mean, variance per income quartile
SELECT income_quartile,
       count(*)                                  AS n,
       round(avg(price_per_sqft), 2)             AS mean_ppsf,
       round(var_samp(price_per_sqft), 2)        AS variance,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY price_per_sqft)::numeric, 2) AS median_ppsf
FROM clean_sales GROUP BY 1 ORDER BY 1;

-- 7b. Two-proportion Z-test inputs and statistic (top vs bottom quartile).
--     p-value in Excel:  =2*(1-NORM.S.DIST(ABS(z),TRUE))
WITH t AS (
    SELECT
        count(*) FILTER (WHERE income_quartile = 4 AND above_county_median = 1)::numeric AS x1,
        count(*) FILTER (WHERE income_quartile = 4)::numeric                             AS n1,
        count(*) FILTER (WHERE income_quartile = 1 AND above_county_median = 1)::numeric AS x2,
        count(*) FILTER (WHERE income_quartile = 1)::numeric                             AS n2
    FROM clean_sales
)
SELECT x1, n1, x2, n2,
       round(x1/n1, 4)                                    AS p1,
       round(x2/n2, 4)                                    AS p2,
       round((x1+x2)/(n1+n2), 4)                          AS pooled_p,
       round(((x1/n1 - x2/n2) /
              sqrt(((x1+x2)/(n1+n2)) * (1-(x1+x2)/(n1+n2)) * (1/n1 + 1/n2)))::numeric, 3) AS z
FROM t;

-- 7c. Welch t-test inputs: renovated vs never renovated
--     Excel:  =T.TEST(range1, range2, 2, 3)
SELECT renovated_flag,
       count(*)                           AS n,
       round(avg(price_per_sqft), 2)      AS mean_ppsf,
       round(var_samp(price_per_sqft), 2) AS variance
FROM clean_sales GROUP BY 1 ORDER BY 1;

-- 7d. Pivot-table checks: price per sq ft by income quartile x grade band
SELECT income_quartile, grade_band, count(*) AS n, round(avg(price_per_sqft), 2) AS mean_ppsf
FROM clean_sales GROUP BY 1, 2 ORDER BY 1, 2;

-- 7e. By year, to show the price-over-time effect
SELECT sale_year, count(*) AS n,
       round(avg(price_per_sqft), 2) AS mean_ppsf,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY price_per_sqft)::numeric, 2) AS median_ppsf
FROM clean_sales GROUP BY 1 ORDER BY 1;


/* =====================================================================
   PART 8. OBJECTIVE 3: HOMES PRICED WELL BELOW COMPARABLES
   A home is flagged when its price per sq ft is below 75% of the median
   for the same ZIP, same condition and same size band (500 sq ft wide),
   and that comparison group has at least 10 sales.
   Change 0.75 and 10 below to tighten or loosen the rule.
   ===================================================================== */
CREATE VIEW underpriced_candidates AS
WITH banded AS (
    SELECT c.*, (floor(sqft_tot_living / 500.0) * 500)::int AS size_band
    FROM clean_sales c
),
gstats AS (   -- median per comparison group (PostgreSQL cannot use percentile_cont as a window)
    SELECT zip_code, condition_code, size_band,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY price_per_sqft) AS group_median_ppsf,
           count(*) AS group_n
    FROM banded
    GROUP BY zip_code, condition_code, size_band
),
grp AS (
    SELECT b.*, g.group_median_ppsf, g.group_n
    FROM banded b
    JOIN gstats g USING (zip_code, condition_code, size_band)
)
SELECT sale_id, excise_tax_nbr, major, minor, sale_year, zip_code, condition_code,
       size_band, sqft_tot_living, sale_price, price_per_sqft,
       round(group_median_ppsf::numeric, 2)                 AS group_median_ppsf,
       group_n,
       round((price_per_sqft / group_median_ppsf)::numeric, 3) AS ratio_to_group_median
FROM grp
WHERE group_n >= 10
  AND price_per_sqft < 0.75 * group_median_ppsf;

SELECT count(*) AS flagged_homes FROM underpriced_candidates;


/* =====================================================================
   PART 9. EXPORTS (files are written to the folder set by \cd above)
   ===================================================================== */
-- 9a. Main export for Excel and Tableau
\copy (SELECT * FROM clean_sales ORDER BY sale_id) TO 'clean_sales_export.csv' WITH (FORMAT csv, HEADER true)

-- 9b. ANOVA layout for the Data Analysis ToolPak: one column per quartile
\copy (SELECT rn, max(p) FILTER (WHERE q = 1) AS q1_lowest, max(p) FILTER (WHERE q = 2) AS q2, max(p) FILTER (WHERE q = 3) AS q3, max(p) FILTER (WHERE q = 4) AS q4_highest FROM (SELECT income_quartile AS q, price_per_sqft AS p, row_number() OVER (PARTITION BY income_quartile ORDER BY sale_id) AS rn FROM clean_sales) s GROUP BY rn ORDER BY rn) TO 'anova_input_wide.csv' WITH (FORMAT csv, HEADER true)

-- 9c. Flagged homes
\copy (SELECT * FROM underpriced_candidates ORDER BY ratio_to_group_median) TO 'underpriced_candidates.csv' WITH (FORMAT csv, HEADER true)


/* =====================================================================
   PART 10. ROW-COUNT LOG (paste this into your report)
   ===================================================================== */
SELECT step_no, step, object_name, row_count, note FROM pipeline_log ORDER BY step_no;
