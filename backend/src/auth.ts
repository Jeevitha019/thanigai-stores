import bcrypt from 'bcryptjs';
import { randomBytes } from 'node:crypto';
import jwt, { JwtPayload } from 'jsonwebtoken';
import { PublicUser, UserRole } from './types';

const bcryptRounds = 12;
const dummyPasswordHash = bcrypt.hashSync(randomBytes(32).toString('hex'), 12);

export interface AuthClaims {
  id: string;
  username: string;
  role: UserRole;
}

export class HttpError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = 'HttpError';
  }
}

export function getJwtSecret(): string {
  const secret = process.env.JWT_SECRET;
  if (!secret || Buffer.byteLength(secret, 'utf8') < 32) {
    throw new Error(
      'Set JWT_SECRET to a randomly generated value of at least 32 bytes in backend/.env.',
    );
  }
  return secret;
}

export async function hashPassword(password: string): Promise<string> {
  return bcrypt.hash(password, bcryptRounds);
}

export async function comparePassword(
  password: string,
  passwordHash: string,
): Promise<boolean> {
  return Buffer.byteLength(password, 'utf8') <= 72
    ? bcrypt.compare(password, passwordHash)
    : false;
}

export async function authenticateUser(
  username: string,
  password: string,
  secret: string,
  findByUsername: (username: string) => Promise<
    | { id: string; username: string; role: UserRole; passwordHash: string }
    | null
  >,
): Promise<{ token: string; user: PublicUser }> {
  const user = await findByUsername(username);
  const passwordHash =
    user && Buffer.byteLength(password, 'utf8') <= 72
      ? user.passwordHash
      : dummyPasswordHash;
  const isValid = await bcrypt.compare(
    password,
    passwordHash,
  );

  if (!user || !isValid) {
    throw new HttpError(401, 'Invalid username or password.');
  }

  const publicUser: PublicUser = {
    id: user.id,
    username: user.username,
    role: user.role,
  };
  const token = jwt.sign(publicUser, secret, {
    algorithm: 'HS256',
    subject: user.id,
    expiresIn: '15m',
  });

  return { token, user: publicUser };
}

export function verifyToken(token: string, secret: string): AuthClaims {
  let payload: string | JwtPayload;
  try {
    payload = jwt.verify(token, secret, { algorithms: ['HS256'] });
  } catch {
    throw new HttpError(401, 'Authentication required.');
  }

  if (
    typeof payload === 'string' ||
    typeof payload.sub !== 'string' ||
    typeof payload.username !== 'string' ||
    (payload.role !== 'admin' && payload.role !== 'cashier')
  ) {
    throw new HttpError(401, 'Authentication required.');
  }

  return {
    id: payload.sub,
    username: payload.username,
    role: payload.role as UserRole,
  };
}

export function validateUsername(value: unknown): string {
  if (
    typeof value !== 'string' ||
    !/^[A-Za-z0-9._-]{3,64}$/.test(value)
  ) {
    throw new HttpError(
      400,
      'Username must be 3–64 characters using letters, numbers, dots, underscores, or hyphens.',
    );
  }
  return value;
}

export function validatePassword(value: unknown): string {
  if (
    typeof value !== 'string' ||
    Array.from(value).length < 4 ||
    Buffer.byteLength(value, 'utf8') > 72
  ) {
    throw new HttpError(
      400,
      'Password must contain at least 4 characters and no more than 72 UTF-8 bytes.',
    );
  }
  return value;
}
