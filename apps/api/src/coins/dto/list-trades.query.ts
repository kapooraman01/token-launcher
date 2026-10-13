import { Type } from 'class-transformer';
import { IsInt, IsOptional, Matches, Max, Min } from 'class-validator';
import { DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE } from '../../common/pagination';

export class ListTradesQuery {
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(MAX_PAGE_SIZE)
  limit: number = DEFAULT_PAGE_SIZE;

  /** Id of the last trade on the previous page. */
  @IsOptional()
  @Matches(/^[1-9]\d{0,17}$/, { message: 'cursor must be a trade id' })
  cursor?: string;
}
