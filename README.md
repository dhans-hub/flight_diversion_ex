# .github-workflows-ci.yml
Tests everything in the background. Even spins up a temporary database to check that the PostGIS spatial queries run , plus it scans the Python code to find bugs before they hit QGIS.
name: Code Quality & Database Syntax Validation

on:
  push:
    branches: [ main, master ]
  pull_request:
    branches: [ main, master ]

jobs:
  validate_codebase:
    runs-on: ubuntu-latest
    
    # Spin up an actual, live PostgreSQL container bundled with PostGIS extension tools
    services:
      postgres:
        image: postgis/postgis:15-3.3
        env:
          POSTGRES_DB: faa_db
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: ci_test_password
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
    - name: Check out Repository Code
      uses: actions/checkout@v4

    - name: Set up Python Runtime Environment
      uses: actions/setup-python@v5
      with:
        python-state: '3.10'

    - name: Install Linting Dependencies
      run: |
        python -m pip install --upgrade pip
        pip install flake8

    - name: Lint QGIS Python Script (Syntax & PEP 8 Checking)
      run: |
        # Stop the build if there are Python syntax errors or undefined names
        flake8 python/ --count --select=E9,F63,F7,F82 --show-source --statistics
        # exit-zero treats all other style warnings as warnings instead of critical failures
        flake8 python/ --count --exit-zero --max-complexity=10 --max-line-length=127 --statistics

    - name: Install Client Database Validation Tooling
      run: |
        sudo apt-get update
        sudo apt-get install -y postgresql-client

    - name: Validate SQL Database Schemas and Extensions
      env:
        PGPASSWORD: ci_test_password
      run: |
        # Check that we can reach the PostgreSQL container
        pg_isready -h localhost -p 5432 -U postgres
        
        # Mock execution of raw database builds to verify syntax stability
        if [ -f sql/dc_region_aviation_postgis.sql ]; then
          echo "Validating baseline script execution..."
          psql -h localhost -p 5432 -U postgres -d faa_db -f sql/dc_region_aviation_postgis.sql
        else
          echo "⚠️ Base dataset script not detected. Skipping step."
        fi

        if [ -f sql/diversion_analysis.sql ]; then
          echo "Validating optimized PostGIS routing syntax execution..."
          psql -h localhost -p 5432 -U postgres -d faa_db -f sql/diversion_analysis.sql
        else
          echo "❌ Critical Error: sql/diversion_analysis.sql file missing!"
          exit 1
        fi
