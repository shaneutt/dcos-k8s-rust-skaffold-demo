use schema::employees;

#[derive(Clone, Debug, Serialize, Deserialize, Queryable, Insertable)]
#[table_name = "employees"]
pub struct Employee {
    pub id:    i32,
    pub fname: String,
    pub lname: String,
    pub age:   i32,
    pub title: String,
}

#[derive(Serialize, Deserialize)]
pub struct EmployeeList {
    pub results: Vec<Employee>,
}
