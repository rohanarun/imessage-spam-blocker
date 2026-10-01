import { IMessageSDK } from '@photon-ai/imessage-kit';
let input = '';
for await (const chunk of process.stdin) input += chunk;
const { after } = JSON.parse(input);
let sdk;
try {
  sdk = new IMessageSDK();
  const rows = await sdk.getMessages({ since: new Date(after), excludeReactions: true });
  const messages = rows.map(m => ({guid:m.id,text:m.text,isFromMe:m.isFromMe,dateCreated:m.createdAt.getTime(),handle:m.participant ? {address:m.participant}:null,chatKind:m.chatKind}));
  process.stdout.write(JSON.stringify(messages));
} catch (error) {
  process.stderr.write('Photon cannot read Messages. Grant Quiet Messages Full Disk Access in System Settings.');
  process.exitCode = 1;
} finally { await sdk?.close(); }
