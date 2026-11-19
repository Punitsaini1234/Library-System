-- Library database setup
CREATE DATABASE IF NOT EXISTS library_db;
USE library_db;

-- Members who can borrow books
CREATE TABLE IF NOT EXISTS members (
    member_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    first_name VARCHAR(80) NOT NULL,
    last_name VARCHAR(80) NOT NULL,
    email VARCHAR(255) NOT NULL,
    phone VARCHAR(30),
    joined_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (member_id),
    UNIQUE KEY uq_members_email (email)
) ENGINE=InnoDB;

-- Book titles (one row per title/edition)
CREATE TABLE IF NOT EXISTS books (
    book_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    isbn VARCHAR(20),
    title VARCHAR(255) NOT NULL,
    publisher VARCHAR(150),
    published_year SMALLINT UNSIGNED,
    PRIMARY KEY (book_id),
    UNIQUE KEY uq_books_isbn (isbn)
) ENGINE=InnoDB;

-- Authors
CREATE TABLE IF NOT EXISTS authors (
    author_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    author_name VARCHAR(180) NOT NULL,
    PRIMARY KEY (author_id),
    UNIQUE KEY uq_authors_name (author_name)
) ENGINE=InnoDB;

-- A book can have multiple authors, and an author can write multiple books
CREATE TABLE IF NOT EXISTS book_authors (
    book_id BIGINT UNSIGNED NOT NULL,
    author_id BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (book_id, author_id),
    CONSTRAINT fk_book_authors_book
        FOREIGN KEY (book_id) REFERENCES books (book_id),
    CONSTRAINT fk_book_authors_author
        FOREIGN KEY (author_id) REFERENCES authors (author_id)
) ENGINE=InnoDB;

-- Each physical copy is tracked separately
CREATE TABLE IF NOT EXISTS book_copies (
    copy_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    book_id BIGINT UNSIGNED NOT NULL,
    accession_code VARCHAR(50) NOT NULL,
    acquired_at DATE,
    PRIMARY KEY (copy_id),
    UNIQUE KEY uq_book_copies_accession (accession_code),
    KEY idx_book_copies_book (book_id),
    CONSTRAINT fk_book_copies_book
        FOREIGN KEY (book_id) REFERENCES books (book_id)
) ENGINE=InnoDB;

-- Each issue/return is recorded as a loan
CREATE TABLE IF NOT EXISTS loans (
    loan_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    copy_id BIGINT UNSIGNED NOT NULL,
    member_id BIGINT UNSIGNED NOT NULL,
    issued_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    due_at DATETIME NOT NULL,
    returned_at DATETIME NULL,

    -- This is copy_id while the loan is active, and NULL after return.
    -- The unique key prevents a copy from having two active loans.
    active_copy_id BIGINT UNSIGNED
        GENERATED ALWAYS AS (
            IF(returned_at IS NULL, copy_id, NULL)
        ) STORED,

    PRIMARY KEY (loan_id),
    UNIQUE KEY uq_loans_one_active_per_copy (active_copy_id),
    KEY idx_loans_member (member_id),
    KEY idx_loans_due_returned (due_at, returned_at),

    CONSTRAINT fk_loans_copy
        FOREIGN KEY (copy_id) REFERENCES book_copies (copy_id),
    CONSTRAINT fk_loans_member
        FOREIGN KEY (member_id) REFERENCES members (member_id)
) ENGINE=InnoDB;

-- Issue a copy safely.
-- The copy row is locked during the check and insert, preventing concurrent
-- requests from issuing the same copy at the same time.
DELIMITER //

CREATE PROCEDURE issue_copy (
    IN p_member_id BIGINT UNSIGNED,
    IN p_copy_id BIGINT UNSIGNED,
    IN p_due_at DATETIME
)
BEGIN
    DECLARE v_locked_copy_id BIGINT UNSIGNED;
    DECLARE v_active_loans INT DEFAULT 0;
    DECLARE v_copy_found BOOLEAN DEFAULT TRUE;

    DECLARE CONTINUE HANDLER FOR NOT FOUND
        SET v_copy_found = FALSE;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_due_at IS NULL OR p_due_at <= CURRENT_TIMESTAMP THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Due date must be in the future';
    END IF;

    START TRANSACTION;

    SELECT copy_id
      INTO v_locked_copy_id
      FROM book_copies
     WHERE copy_id = p_copy_id
     FOR UPDATE;

    IF v_copy_found = FALSE THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Book copy does not exist';
    END IF;

    SELECT COUNT(*)
      INTO v_active_loans
      FROM loans
     WHERE copy_id = p_copy_id
       AND returned_at IS NULL;

    IF v_active_loans > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Book copy is already issued';
    END IF;

    INSERT INTO loans (copy_id, member_id, due_at)
    VALUES (p_copy_id, p_member_id, p_due_at);

    COMMIT;
END//

-- Return a loan. The loan record stays in the database for history.
CREATE PROCEDURE return_loan (
    IN p_loan_id BIGINT UNSIGNED
)
BEGIN
    DECLARE v_returned_at DATETIME;
    DECLARE v_loan_found BOOLEAN DEFAULT TRUE;

    DECLARE CONTINUE HANDLER FOR NOT FOUND
        SET v_loan_found = FALSE;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT returned_at
      INTO v_returned_at
      FROM loans
     WHERE loan_id = p_loan_id
     FOR UPDATE;

    IF v_loan_found = FALSE THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Loan does not exist';
    END IF;

    IF v_returned_at IS NOT NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'This loan has already been returned';
    END IF;

    UPDATE loans
       SET returned_at = CURRENT_TIMESTAMP
     WHERE loan_id = p_loan_id;

    COMMIT;
END//

DELIMITER ;

-- Sample data (IDs are explicit to make the example calls predictable)
INSERT IGNORE INTO members
    (member_id, first_name, last_name, email, phone)
VALUES
    (1, 'Asha', 'Sharma', 'asha@example.com', '555-0101'),
    (2, 'Ravi', 'Kumar', 'ravi@example.com', '555-0102');

INSERT IGNORE INTO books
    (book_id, isbn, title, publisher, published_year)
VALUES
    (1, '9780132350884', 'Clean Code', 'Prentice Hall', 2008),
    (2, '9780201616224', 'The Pragmatic Programmer', 'Addison-Wesley', 1999);

INSERT IGNORE INTO authors
    (author_id, author_name)
VALUES
    (1, 'Robert C. Martin'),
    (2, 'Andrew Hunt'),
    (3, 'David Thomas');

INSERT IGNORE INTO book_authors (book_id, author_id)
VALUES
    (1, 1),
    (2, 2),
    (2, 3);

INSERT IGNORE INTO book_copies
    (copy_id, book_id, accession_code, acquired_at)
VALUES
    (1, 1, 'COPY-0001', '2025-01-15'),
    (2, 1, 'COPY-0002', '2025-01-15'),
    (3, 2, 'COPY-0003', '2025-02-01');

    SELECT
    b.title,
    bc.copy_id,
    bc.accession_code
FROM book_copies AS bc
JOIN books AS b ON b.book_id = bc.book_id
LEFT JOIN loans AS l
    ON l.copy_id = bc.copy_id
   AND l.returned_at IS NULL
WHERE l.loan_id IS NULL
ORDER BY b.title, bc.copy_id;

CALL issue_copy(1, 1, DATE_ADD(CURRENT_TIMESTAMP, INTERVAL 14 DAY));

SELECT
    l.loan_id,
    m.first_name,
    m.last_name,
    b.title,
    bc.accession_code,
    l.issued_at,
    l.due_at
FROM loans AS l
JOIN members AS m ON m.member_id = l.member_id
JOIN book_copies AS bc ON bc.copy_id = l.copy_id
JOIN books AS b ON b.book_id = bc.book_id
WHERE l.returned_at IS NULL
ORDER BY l.due_at;

CALL return_loan(1);

SELECT
    l.loan_id,
    m.first_name,
    m.last_name,
    b.title,
    l.due_at
FROM loans AS l
JOIN members AS m ON m.member_id = l.member_id
JOIN book_copies AS bc ON bc.copy_id = l.copy_id
JOIN books AS b ON b.book_id = bc.book_id
WHERE l.returned_at IS NULL
  AND l.due_at < CURRENT_TIMESTAMP
ORDER BY l.due_at;

SELECT
    l.loan_id,
    b.title,
    bc.accession_code,
    l.issued_at,
    l.due_at,
    l.returned_at
FROM loans AS l
JOIN book_copies AS bc ON bc.copy_id = l.copy_id
JOIN books AS b ON b.book_id = bc.book_id
WHERE l.member_id = 1
ORDER BY l.issued_at DESC;