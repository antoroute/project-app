const express = require('express');
const app = express();

app.get('/api/health', (req, res) => res.send('Auth OK'));

app.listen(process.env.PORT || 3000, () =>
  console.log(`Auth listening on port ${process.env.PORT || 3000}`)
);