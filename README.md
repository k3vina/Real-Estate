# Real Estate
# Location or Renovation? What Drives Home Prices in King County, WA

Is a home's sale price per square foot more closely tied to the income of its neighborhood than to the build quality of the house itself?

**Tools:** Excel and Power Query (cleaning, statistical tests), PostgreSQL (staging, joins, modeling), Tableau Public (dashboard).

## Links

| Deliverable | Link |
|---|---|
| Tableau Public dashboard | https://public.tableau.com/app/profile/kevina.jepkonga/viz/RealEstateDashboard_17951864523670/Dashboard1 |
| Slides (5 to 7 minute presentation) | [add link] |
| Article | https://medium.com/@kevinajepkonga/location-or-renovation-what-108-441-home-sales-reveal-about-king-county-real-estate-54541bcb2ad8?postPublishedType=repub |

## The question and the decision it supports

A buyer or small-scale investor can buy a modest house in a high-income area, or a higher-grade house in a lower-income area and renovate it. If location dominates, prioritize the neighborhood. If build quality dominates, renovation is the better lever.

**Hypothesis:** neighborhood income shows a stronger correlation with price per sq ft than building grade does.

## Data

| Source | What it provides | Join key |
|---|---|---|
| King County Department of Assessments open data (Real Property Sales, Residential Building, lookup codes) | Sale price and date, living area, building grade, condition, year built, year renovated | Major + Minor parcel ID |
| U.S. Census Bureau, American Community Survey 5-year estimates, table B19013 (2024 vintage, covering 2020 to 2024) | Median household income by ZIP code area | ZIP code |

Sales from 2020 to 2026 are used. Every sale, including 2025 and 2026, is matched to the same 2024 ACS income estimate, which assumes neighborhood income rankings stayed stable. 2026 is a partial year.

The raw files are large and are not stored in this repository. Download them from the sources above. [Add exact download page links.]

## Pipeline

1. **Excel / Power Query:** each raw CSV is cleaned and the four sources are joined into `real_estate_clean.csv` (108,990 sales, one row per sale). Major, Minor and ZIP are kept as text to preserve leading zeros. Non-market sales and price outliers are removed here. [Confirm and describe the exact rules.]
2. **PostgreSQL:** `sql/real_estate_postgres.sql` loads the CSV into a text-only staging table with `\copy`, casts it into a typed table with constraints, builds the `clean_sales` view, runs the modeling queries and exports CSVs. Row counts at each step are logged in `pipeline_log`.
3. **Excel:** the three hypothesis tests (ToolPak ANOVA, two-proportion Z-test with `NORM.S.DIST`, Welch t-test with `T.TEST`) at alpha = 0.05.
4. **Tableau Public:** dashboard built from the exported `clean_sales_export.csv`, because Tableau Public works from file extracts, not a live PostgreSQL connection.

### Row counts

| Step | Rows |
|---|---|
| Staging table (raw CSV, all text) | 108,990 |
| Typed table | 108,990 |
| `clean_sales` view | 108,441 |

The 549 rows removed from `clean_sales` are sales where the home was built or renovated after the sale year (306 built after the sale, 243 renovated after the sale), where the price describes a different house.

### What `clean_sales` adds

`price_per_sqft`, `income_quartile` (quartiles cut across the 88 ZIP codes, not across sales), `grade_band` (3 to 6, 7, 8, 9 to 13), `renovated_flag`, `sale_year` and `above_county_median` (1 if price per sq ft is above the median of 481.22 across `clean_sales`).

## How to run the SQL

1. Create a database: `CREATE DATABASE real_estate;`
2. Open `sql/real_estate_postgres.sql` and edit the `\cd` line in Part 1 to the folder that holds `real_estate_clean.csv`.
3. Run it: `psql -U postgres -d real_estate -f sql/real_estate_postgres.sql`

The script creates the schema `capstone`, drops and rebuilds only its own tables and views, and writes three CSVs next to the input file: `clean_sales_export.csv`, `anova_input_wide.csv` (one column per income quartile, the layout the ToolPak needs) and `underpriced_candidates.csv`. In pgAdmin, `\copy` does not work: use its Import/Export tool for the load and the exports. Tested on PostgreSQL 16.

## Results

108,441 sales, 88 ZIP codes, 2020 to 2026.

### Correlation with price per sq ft

| Measure | Pearson | Spearman |
|---|---|---|
| Neighborhood income (ZIP median) | 0.38 | 0.42 |
| Building grade | 0.18 | 0.14 |

Income explains about 15% of the variation in price per sq ft (r² = 0.146) and grade about 3% (r² = 0.033).

### Price per sq ft by income quartile

| Quartile | Sales | Mean $/sq ft | Median $/sq ft | Share above county median |
|---|---|---|---|---|
| Q1 (lowest income) | 16,827 | 423.42 | 392.38 | 28.8% |
| Q2 | 27,640 | 427.37 | 394.90 | 30.4% |
| Q3 | 33,664 | 521.61 | 505.00 | 55.0% |
| Q4 (highest income) | 30,310 | 615.18 | 586.03 | 74.0% |

### Hypothesis tests (alpha = 0.05)

| Test | H0 | Statistic | p-value | Gap |
|---|---|---|---|---|
| ANOVA, single factor | Mean price per sq ft is equal across the four income quartiles | F(3, 108,437) = 6,966 | < 0.0001 | Q4 $615 vs Q1 $423; eta squared 0.16 |
| Two-proportion Z-test | The share of above-median sales is the same in the top and bottom quartiles | z = 95.1 | < 0.0001 | 74.0% vs 28.8% (95% CI for the difference: 44.3 to 46.0 points) |
| Welch t-test | Mean price per sq ft is equal for renovated and never-renovated homes | t = 28.8, df about 7,463 | < 0.0001 | $585.68 vs $503.32 (difference $82.37, 95% CI $76.77 to $87.97) |

A follow-up Tukey comparison after the ANOVA shows Q1 and Q2 are not meaningfully different (difference $3.95, p = 0.10); every other pair differs (p < 0.001).

**What the p-values do not mean:** a p-value is not the probability that H0 is true. It is the probability of a gap at least this large if H0 were true. With over 100,000 sales almost any gap is significant, so the size of the gap matters more than the p-value.

### Renovation premium within each income quartile

| Quartile | Never renovated (mean $/sq ft) | Renovated (mean $/sq ft) | Difference |
|---|---|---|---|
| Q1 | 420.4 | 469.7 | 49.3 |
| Q2 | 422.1 | 501.5 | 79.4 |
| Q3 | 516.9 | 592.3 | 75.4 |
| Q4 | 608.0 | 722.0 | 114.0 |

## Limitations

- **Income is measured by ZIP code, not by buyer.** The finding is about neighborhoods, not individual purchasers.
- **Location and quality are entangled.** Expensive areas also tend to have better-built homes, so correlation does not separate the two.
- **The measure matters.** Across the cleaned sales, building grade correlates more strongly with total sale price (0.67) than income does (0.47). Price per sq ft favors small homes, which weakens grade's correlation with it.
- **Renovation was not randomly assigned.** A significant result shows the groups differ, not that renovation caused it.
- **Prices change over time.** Median price per sq ft rose about 37% from 2020 to 2026 (about $386 to $529). Figures are not adjusted for inflation.
- **Repeat sales.** Some parcels sell more than once (up to four times in this data), so rows are not fully independent.
- **Top-coded income.** ZIPs 98039 and 98075 carry the Census `250,000+` value, entered as 250000. They fall in the top quartile either way.

## Repository contents

```
README.md
sql/real_estate_postgres.sql      schema, loading, checks, clean_sales view, modeling, exports
excel/                            workbook with the three tests [add]
tableau/                          Tableau workbook [add]
```
