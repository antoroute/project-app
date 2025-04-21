import jwt from 'jsonwebtoken';

app.authenticate = function (req, res, next) {
  const authHeader = req.headers['authorization'];
  const token = authHeader?.split(' ')[1];
  if (!token) return res.status(401).send({ error: 'No token provided' });

  try {
    const decoded = jwt.verify(token, process.env.JWT_SECRET);
    req.user = decoded;
    next();
  } catch (err) {
    return res.status(403).send({ error: 'Invalid or expired token' });
  }
};

export function groupRoutes(app) {
    const pool = app.pg;
  
    // Créer un groupe
    app.post('/groups', app.authenticate, async (req, res) => {
      const { name, publicKeyGroup } = req.body;
      const userId = req.user.id;
  
      try {
        const group = await pool.query(
          'INSERT INTO groups (name) VALUES ($1) RETURNING id',
          [name]
        );
  
        await pool.query(
          'INSERT INTO user_groups (user_id, group_id, public_key_group) VALUES ($1, $2, $3)',
          [userId, group.rows[0].id, publicKeyGroup]
        );
  
        res.status(201).send({ groupId: group.rows[0].id });
      } catch (err) {
        console.error(err);
        res.status(400).send({ error: 'Group creation failed' });
      }
    });
  
    // Rejoindre un groupe existant
    app.post('/groups/:id/join', app.authenticate, async (req, res) => {
        const groupId = req.params.id;
        const userId = req.user.id;
        const { publicKeyGroup } = req.body;
      
        // ✅ Optionnel : vérifier que le groupe existe
        const groupExists = await pool.query('SELECT 1 FROM groups WHERE id = $1', [groupId]);
        if (groupExists.rowCount === 0) {
          return res.status(404).send({ error: 'Group not found' });
        }
      
        try {
          const existing = await pool.query(
            'SELECT 1 FROM user_groups WHERE user_id = $1 AND group_id = $2',
            [userId, groupId]
          );
          if (existing.rowCount > 0) {
            return res.status(409).send({ error: 'Already joined' });
          }
      
          await pool.query(
            'INSERT INTO user_groups (user_id, group_id, public_key_group) VALUES ($1, $2, $3)',
            [userId, groupId, publicKeyGroup]
          );
      
          res.status(201).send({ joined: true });
        } catch (err) {
          console.error(err);
          res.status(400).send({ error: 'Join failed' });
        }
    });      
  
    // Voir les membres d’un groupe
    app.get('/groups/:id/members', app.authenticate, async (req, res) => {
        const groupId = req.params.id;
        const userId = req.user.id;
      
        // Vérifie que l'utilisateur fait bien partie du groupe
        const isMember = await pool.query(
          'SELECT 1 FROM user_groups WHERE user_id = $1 AND group_id = $2',
          [userId, groupId]
        );
      
        if (isMember.rowCount === 0) {
          return res.status(403).send({ error: 'Forbidden: not a group member' });
        }
      
        try {
          const members = await pool.query(`
            SELECT u.id AS "userId", u.email, ug.public_key_group AS "publicKeyGroup"
            FROM user_groups ug
            JOIN users u ON u.id = ug.user_id
            WHERE ug.group_id = $1
          `, [groupId]);
      
          res.send(members.rows);
        } catch (err) {
          console.error(err);
          res.status(500).send({ error: 'Failed to fetch members' });
        }
    });
}
  