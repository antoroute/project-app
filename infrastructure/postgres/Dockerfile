FROM postgres:15
COPY init.sql /docker-entrypoint-initdb.d/
COPY pg_hba.conf /etc/postgresql/pg_hba.conf