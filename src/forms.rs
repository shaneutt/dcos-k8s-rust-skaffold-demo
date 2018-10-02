use schema::employees;

#[derive(Clone, Debug, Serialize, Deserialize, FromForm, Insertable, AsChangeset)]
#[table_name = "employees"]
pub struct EmployeeForm {
    pub id:    Option<i32>,
    pub fname: Option<String>,
    pub lname: Option<String>,
    pub age:   Option<i32>,
    pub title: Option<String>,
}
