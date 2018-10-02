CREATE TABLE employees (
    id         SERIAL PRIMARY KEY,
    fname      VARCHAR NOT NULL,
    lname      VARCHAR NOT NULL,
    age        INTEGER NOT NULL,
    title      VARCHAR NOT NULL
);
