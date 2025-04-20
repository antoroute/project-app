const express = require('express');
const app = express();

app.get('/health', (req, res) => res.send('Messaging OK'));

app.listen(process.env.PORT || 3001, () =>
  console.log(`Messaging listening on port ${process.env.PORT || 3001}`)
);