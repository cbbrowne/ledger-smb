SELECT count(*), customernumber from customer
GROUP BY customernumber
HAVING count(*) > 1;

SELECT count(*), vendornumber from vendor
GROUP BY vendornumber
HAVING count(*) > 1;

SELECT * FROM chart where link LIKE '%CT_tax%';

SELECT * FROM employee where employeenumber IS NULL;

SELECT * FROM employee WHERE employeenumber IN 
       (SELECT employeenumber FROM employee GROUP BY employeenumber
        HAVING count(*) > 1);

select partnumber, count(*) from parts 
 WHERE obsolete is not true
group by partnumber having count(*) > 1;

SELECT invnumber, count(*) from ar
group by invnumber having count(*) > 1;

