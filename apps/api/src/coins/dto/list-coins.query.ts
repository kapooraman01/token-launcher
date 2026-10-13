import { Type } from 'class-transformer';
import {
  IsEthereumAddress,
  IsInt,
  IsOptional,
  Max,
  Min,
} from 'class-validator';
import { DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE } from '../../common/pagination';

export class ListCoinsQuery {
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(MAX_PAGE_SIZE)
  limit: number = DEFAULT_PAGE_SIZE;

  /** Address of the last coin on the previous page. */
  @IsOptional()
  @IsEthereumAddress()
  cursor?: string;
}
