import { ProductInput } from './product-types';

export type UserRole = 'admin' | 'cashier';

export interface PublicUser {
  id: string;
  username: string;
  role: UserRole;
}

export interface StoredUser extends PublicUser {
  passwordHash: string;
}

export interface AuthRepository {
  findByUsername(username: string): Promise<StoredUser | null>;
  findById(id: string): Promise<PublicUser | null>;
  hasAdmin?(): Promise<boolean>;
  createInitialAdmin?(
    username: string,
    passwordHash: string,
    sampleProducts?: ProductInput[],
  ): Promise<PublicUser>;
  createCashier(
    username: string,
    passwordHash: string,
    createdBy?: string,
  ): Promise<PublicUser>;
  changePassword?(
    id: string,
    passwordHash: string,
    actorId?: string,
  ): Promise<void>;
  recordLogin?(id: string): Promise<void>;
}
