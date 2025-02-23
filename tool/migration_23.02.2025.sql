-- SQL query to get all verified users with their chatId, userId, name, verifiedAt and reason
WITH msgs AS (
    SELECT sender_id, chat_id, MIN(unixtime) AS first_message_time
    FROM messages
    GROUP BY sender_id
)
SELECT
    m.chat_id AS chatId,
    v.id AS userId,
    MAX(
        COALESCE(
            NULLIF(TRIM(TRIM(u.first_name) || ' ' || TRIM(u.last_name)), ''),
            NULLIF(TRIM(u.username), ''),
            'unknown'
        )
    ) AS name,
    MIN(strftime('%s', v.updated_at)) AS verifiedAt,
    "migrated_23.02.2025" AS reason -- MAX(v.reason) AS reason
FROM verified AS v
LEFT JOIN users AS u ON v.id = u.id
LEFT JOIN msgs AS m ON v.id = m.sender_id
WHERE
	m.chat_id IS NOT NULL
	AND
	v.id IS NOT NULL
	AND
	v.reason != "Not banned"
GROUP BY v.id;
